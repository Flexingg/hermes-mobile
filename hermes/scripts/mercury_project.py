#!/usr/bin/env python3
"""Link GitHub repos as Mercury projects (run by Hermes, one JSON object out).

    mercury_project.py link Flexingg/lumen-launcher --coder claude [--gates CMD] [--path DIR]
    mercury_project.py list
    mercury_project.py set lumen-launcher --coder agy --gates "./gradlew test"
    mercury_project.py unlink lumen-launcher

`link` is idempotent: it reuses an existing local clone and `dev-<repo>` profile,
creates the kanban board, Hermes project and `mercury` label if missing, installs
the worker skills into the profile, and records the project in the registry.
`unlink` only forgets the project; the repo, profile and memory stay.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import time
from pathlib import Path

from mercury_common import (CODERS, HERMES_ROOT, REAL_HOME, REPO_RE, MercuryError, emit, gh,
                            get_project, hermes, load_projects, main_guard, run, save_projects, slug)

TEMPLATE_PROFILE = os.environ.get("MERCURY_TEMPLATE_PROFILE", "dev-hermes-mobile")
REPOS_DIR = Path(os.environ.get("MERCURY_REPOS_DIR") or REAL_HOME / "repos")
WORKER_SKILLS = ("issue-planner", "ship-issue")


def detect_gates(path: Path) -> str:
    """The repo's own fast checks, the ones a contributor runs locally."""
    if (path / "pubspec.yaml").exists():
        return "flutter analyze && flutter test"
    if (path / "gradlew").exists():
        # capped workers: this box has ~4 GB free and runs other jobs
        return "./gradlew --no-daemon --max-workers=2 testDebugUnitTest"
    if (path / "package.json").exists():
        return "npm test"
    if (path / "pytest.ini").exists() or (path / "conftest.py").exists() or \
            "[tool.pytest" in _read(path / "pyproject.toml") or "[tool:pytest]" in _read(path / "setup.cfg"):
        return "python3 -m pytest -q"
    if (path / "tests").is_dir() or any(path.glob("test_*.py")):
        # no pytest configuration: stdlib unittest runs test_*.py without extra packages
        return "python3 -m unittest discover -q" + (" -s tests" if (path / "tests").is_dir() else "")
    return ""


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return ""


def _remote_matches(path: Path, repo: str) -> bool:
    p = run(["git", "-C", str(path), "remote", "get-url", "origin"], check=False, timeout=10)
    url = (p.stdout or "").strip().lower()
    return url.endswith(f"{repo.lower()}.git") or url.endswith(repo.lower())


def find_clone(repo: str) -> Path | None:
    name = repo.split("/", 1)[1]
    guess = REPOS_DIR / name
    if (guess / ".git").exists() and _remote_matches(guess, repo):
        return guess
    if REPOS_DIR.is_dir():
        for d in sorted(REPOS_DIR.iterdir()):
            if (d / ".git").exists() and _remote_matches(d, repo):
                return d
    return None


def ensure_profile(name: str, repo: str) -> tuple[str, bool]:
    home = HERMES_ROOT / "profiles" / name
    if (home / "config.yaml").exists():
        return name, False
    hermes("profile", "create", name, "--clone-from", TEMPLATE_PROFILE, "--no-alias",
           "--description", f"Coding agent for {repo}: plans issues and ships them as PRs.")
    # The clone copied the template's API_SERVER_KEY: give this profile its own,
    # since the gateway authenticates /p/<profile>/ per profile.
    env = home / ".env"
    lines = env.read_text(encoding="utf-8").splitlines() if env.exists() else []
    lines = [ln for ln in lines if not ln.startswith("API_SERVER_KEY=")]
    lines.append(f"API_SERVER_KEY={secrets.token_urlsafe(32)}")
    env.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.chmod(env, 0o600)
    return name, True


def install_worker_skills(profile: str) -> list[str]:
    src_root = HERMES_ROOT / "skills" / "mercury"
    dst_root = HERMES_ROOT / "profiles" / profile / "skills" / "mercury"
    dst_root.mkdir(parents=True, exist_ok=True)
    done = []
    for skill in WORKER_SKILLS:
        src, dst = src_root / skill, dst_root / skill
        if not src.exists():
            raise MercuryError(f"skill {skill} is not installed: run hermes/install.sh first")
        if dst.is_symlink() or dst.exists():
            if dst.is_symlink() and os.readlink(dst) == str(src):
                done.append(skill)
                continue
            if dst.is_symlink():
                dst.unlink()
            else:
                raise MercuryError(f"{dst} exists and is not a Mercury symlink")
        dst.symlink_to(src)
        done.append(skill)
    return done


def ensure_board_and_project(pid: str, name: str, path: Path) -> None:
    boards = hermes("kanban", "boards", "list", check=False).stdout or ""
    if not re.search(rf"(^|\s){re.escape(pid)}(\s|$)", boards, re.M):
        hermes("kanban", "boards", "create", pid)
    show = hermes("project", "show", pid, check=False)
    if show.returncode != 0:
        hermes("project", "create", name, str(path), "--slug", pid, "--board", pid)
        return
    text = show.stdout or ""
    if f"board:   {pid}" not in text:
        hermes("project", "bind-board", pid, pid)
    # kanban anchors task worktrees on the project's primary folder: it must be
    # the clone the registry points at, not wherever the project once lived
    primary = re.search(r"^\s*primary:\s*(.+?)\s*$", text, re.M)
    if not primary or Path(primary.group(1)) != path:
        hermes("project", "add-folder", pid, str(path), "--primary")


def ensure_board_workdir(pid: str, path: Path) -> None:
    """Backstop: a worktree task that somehow lacks a project path still has a repo."""
    hermes("kanban", "boards", "set-default-workdir", pid, str(path))


def cmd_link(a) -> int:
    repo = a.repo.strip()
    if not REPO_RE.match(repo):
        raise MercuryError(f"not an owner/name repo: {repo!r}")
    if a.coder not in CODERS:
        raise MercuryError(f"coder must be one of {', '.join(CODERS)}")
    info = gh("repo", "view", repo, "--json", "name,nameWithOwner,defaultBranchRef")
    meta = json.loads(info.stdout)
    repo = meta["nameWithOwner"]
    name = meta["name"]
    pid = slug(name)
    default_branch = (meta.get("defaultBranchRef") or {}).get("name") or "main"

    path = Path(a.path).expanduser() if a.path else find_clone(repo)
    cloned = False
    if path is None:
        path = REPOS_DIR / name
        if path.exists():
            raise MercuryError(f"{path} exists but is not a clone of {repo}")
        gh("repo", "clone", repo, str(path), timeout=600)
        cloned = True
    elif not (path / ".git").exists():
        raise MercuryError(f"{path} is not a git repository")

    existing = {p["id"]: p for p in load_projects()}
    prev = existing.get(pid, {})
    profile, created = ensure_profile(a.profile or prev.get("profile") or f"dev-{pid}", repo)
    ensure_board_and_project(pid, name, path)
    ensure_board_workdir(pid, path)
    gh("label", "create", "mercury", "-R", repo, "--color", "5319E7",
       "--description", "Queued for Hermes via Mercury", check=False)
    skills = install_worker_skills(profile)

    project = {
        **prev,
        "id": pid,
        "name": name,
        "repo": repo,
        "path": str(path),
        "profile": profile,
        "board": pid,
        "defaultBranch": default_branch,
        "coder": a.coder or prev.get("coder") or "claude",
        "gates": a.gates if a.gates is not None else prev.get("gates", detect_gates(path)),
        "idleSleepMinutes": prev.get("idleSleepMinutes", 10),
        "linkedAt": prev.get("linkedAt", time.time()),
    }
    existing[pid] = project
    save_projects(list(existing.values()))
    return emit({"ok": True, "project": project, "cloned": cloned, "profileCreated": created,
                 "skills": skills})


def cmd_list(a) -> int:
    return emit({"ok": True, "projects": load_projects()})


def cmd_set(a) -> int:
    project = get_project(a.project)
    if a.coder is not None:
        if a.coder not in CODERS:
            raise MercuryError(f"coder must be one of {', '.join(CODERS)}")
        project["coder"] = a.coder
    if a.gates is not None:
        project["gates"] = a.gates
    if a.idle is not None:
        if a.idle < 1:
            raise MercuryError("idle minutes must be at least 1")
        project["idleSleepMinutes"] = a.idle
    save_projects([p for p in load_projects() if p["id"] != project["id"]] + [project])
    return emit({"ok": True, "project": project})


def cmd_unlink(a) -> int:
    project = get_project(a.project)
    save_projects([p for p in load_projects() if p["id"] != project["id"]])
    return emit({"ok": True, "unlinked": project["id"],
                 "kept": ["repository", "profile", "memory", "kanban board"]})


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("link")
    s.add_argument("repo")
    s.add_argument("--coder", default="claude")
    s.add_argument("--gates", default=None, help="verification command (default: detected)")
    s.add_argument("--path", default=None, help="local clone (default: found or cloned under ~/repos)")
    s.add_argument("--profile", default=None, help="Hermes profile (default: dev-<repo>)")
    sub.add_parser("list")
    s = sub.add_parser("set")
    s.add_argument("project")
    s.add_argument("--coder")
    s.add_argument("--gates")
    s.add_argument("--idle", type=int)
    s = sub.add_parser("unlink")
    s.add_argument("project")
    a = ap.parse_args()
    return main_guard(lambda: {"link": cmd_link, "list": cmd_list, "set": cmd_set,
                               "unlink": cmd_unlink}[a.cmd](a))


if __name__ == "__main__":
    raise SystemExit(main())
