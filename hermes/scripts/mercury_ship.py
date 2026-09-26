#!/usr/bin/env python3
"""The mechanical end of shipping an issue (run by the project's Hermes worker).

    mercury_ship.py prepare --project P --task T --worktree DIR
    mercury_ship.py publish --project P --task T --worktree DIR --title TITLE --notes notes.md
    mercury_ship.py block   --project P --task T --reason "why a person is needed"

`prepare` installs the push guard on this worktree only and records the task as
working. `publish` stages the files the task changed (never secrets or data
dumps), commits, pushes without force, opens (or reuses) the PR with
"Closes #N", records it, and moves the kanban task to review. `block` parks the
task with its reason so Mercury shows "Needs you".
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import time
from pathlib import Path

from mercury_common import (HERMES_ROOT, MercuryError, emit, get_project, gh, hermes, main_guard,
                            run, task_state, update_task_state)
from mercury_code import NEVER_COMMIT, changed_files, git

HOOKS_DIR = HERMES_ROOT / "mercury" / "hooks"
APKS = HERMES_ROOT / "mercury" / "apks"
# Where the gates leave a debug APK (Gradle app module, Flutter)
APK_GLOBS = ("app/build/outputs/apk/debug/*.apk", "build/app/outputs/flutter-apk/app-debug.apk")
_PR_URL_RE = re.compile(r"https://github\.com/[^/\s]+/[^/\s]+/pull/(\d+)")


def branch_prefix(project: dict) -> str:
    # Hermes names task branches <project>/t_<id>-<slug> (Phase 0 finding)
    return f"{project['id']}/t_"


def check_branch(project: dict, worktree: Path) -> str:
    branch = git(worktree, "rev-parse", "--abbrev-ref", "HEAD")
    if branch == project.get("defaultBranch", "main") or not branch.startswith(branch_prefix(project)):
        raise MercuryError(f"branch {branch!r} is not a task branch ({branch_prefix(project)}*)")
    return branch


# Untracked machine config a build needs: a worktree has no copy. Only the SDK
# path lines are carried over, never anything else such a file may hold.
LOCAL_CONFIG = ("local.properties", "android/local.properties")
_SDK_LINE = re.compile(r"^(sdk\.dir|flutter\.sdk)=")


def carry_local_config(project: dict, worktree: Path) -> list[str]:
    done = []
    for rel in LOCAL_CONFIG:
        src, dst = Path(project["path"]) / rel, worktree / rel
        if not src.is_file() or dst.exists() or not dst.parent.is_dir():
            continue
        lines = [ln for ln in src.read_text(encoding="utf-8", errors="ignore").splitlines() if _SDK_LINE.match(ln)]
        if lines:
            dst.write_text("\n".join(lines) + "\n", encoding="utf-8")
            done.append(rel)
    return done


def cmd_prepare(a) -> int:
    project = get_project(a.project)
    worktree = Path(a.worktree).resolve()
    branch = check_branch(project, worktree)
    hook = HOOKS_DIR / "pre-push"
    if not hook.exists():
        raise MercuryError(f"{hook} is missing: run hermes/install.sh")
    git(worktree, "config", "extensions.worktreeConfig", "true")
    git(worktree, "config", "--worktree", "core.hooksPath", str(HOOKS_DIR))
    git(worktree, "config", "--worktree", "mercury.allowedBranchPrefix", branch_prefix(project))
    carried = carry_local_config(project, worktree)
    state = update_task_state(a.task, project=project["id"], worktree=str(worktree), branch=branch,
                              phase="working", preparedAt=time.time())
    return emit({"ok": True, "branch": branch, "guard": "pre-push installed for this worktree only",
                 "localConfig": carried,
                 "issue": state.get("issue"), "coder": project.get("coder", "claude"),
                 "gates": project.get("gates", "")})


def keep_local_apk(project: dict, worktree: Path, state: dict, pr_number: int, head: str) -> str | None:
    """The debug APK the gates built during this task, kept as the PR head's test
    build (for repos whose CI doesn't build one on PRs). Older files are ignored:
    a stale APK from before the task would be a different app."""
    since = float(state.get("preparedAt") or 0)
    fresh = [p for pattern in APK_GLOBS for p in worktree.glob(pattern) if p.stat().st_mtime >= since]
    if not fresh:
        return None
    src = max(fresh, key=lambda p: p.stat().st_mtime)
    dest = APKS / project["id"] / f"pr{pr_number}-{head[:7]}-local.apk"
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    return str(dest)


def cmd_publish(a) -> int:
    project = get_project(a.project)
    worktree = Path(a.worktree).resolve()
    branch = check_branch(project, worktree)
    state = task_state(a.task)
    number = state.get("issue")
    notes = Path(a.notes).read_text(encoding="utf-8").strip() if a.notes else ""
    if not notes:
        raise MercuryError("publish needs --notes: what changed, and what was and wasn't verified")

    # the task title is "#<n> <issue title>"; the commit adds "(#n)" itself
    title = re.sub(r"^#\d+\s+", "", a.title.strip()) or a.title.strip()
    files = changed_files(worktree)
    skipped = [f for f in files if NEVER_COMMIT.search(f)]
    stage = [f for f in files if f not in skipped]
    if stage:
        git(worktree, "add", "--", *stage)
        message = title + (f" (#{number})" if number else "")
        if number:
            message += f"\n\nCloses #{number}"
        git(worktree, "commit", "-m", message)
    base = project.get("defaultBranch", "main")
    run(["git", "-C", str(worktree), "fetch", "-q", "origin", base], timeout=120, check=False)
    ahead = git(worktree, "rev-list", "--count", f"origin/{base}..HEAD", check=False) or "0"
    if int(ahead or 0) == 0:
        raise MercuryError("nothing to publish: no changes and no commits ahead of " + base)
    git(worktree, "push", "-u", "origin", f"HEAD:refs/heads/{branch}")

    existing = gh("pr", "list", "-R", project["repo"], "--head", branch, "--state", "open",
                  "--json", "number,url", check=False)
    prs = json.loads(existing.stdout or "[]") if existing.returncode == 0 else []
    if prs:
        pr_number, pr_url = prs[0]["number"], prs[0]["url"]
    else:
        body = notes
        if number:
            body += f"\n\nCloses #{number}"
        body += f"\n\n---\nShipped by Hermes via Mercury · coder: {a.coder or project.get('coder', 'claude')}"
        out = gh("pr", "create", "-R", project["repo"], "--base", base, "--head", branch,
                 "--title", title, "--body-file", "-", input=body)
        m = _PR_URL_RE.search(out.stdout or "")
        if not m:
            raise MercuryError(f"gh did not return a PR URL: {(out.stdout or '')[-200:]}")
        pr_number, pr_url = int(m.group(1)), m.group(0)
    head = git(worktree, "rev-parse", "HEAD")
    apk = keep_local_apk(project, worktree, state, pr_number, head)
    update_task_state(a.task, prUrl=pr_url, prNumber=pr_number, phase="review", ci="pending",
                      coder=a.coder or project.get("coder"), headSha=head,
                      localApk=apk, localApkSha=head if apk else None)
    hermes("kanban", "--board", project["board"], "comment", a.task, f"PR: {pr_url}", check=False)
    hermes("kanban", "--board", project["board"], "request-review", a.task,
           "--summary", f"PR #{pr_number} opened: {pr_url}", check=False)
    return emit({"ok": True, "pr": pr_url, "prNumber": pr_number, "committed": stage,
                 "notCommitted": skipped, "branch": branch, "testBuild": apk})


def cmd_block(a) -> int:
    project = get_project(a.project)
    update_task_state(a.task, phase="needs_you", blockedReason=a.reason)
    hermes("kanban", "--board", project["board"], "block", a.task, "--kind", "needs_input", a.reason)
    return emit({"ok": True, "task": a.task, "blocked": a.reason})


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("prepare", "publish", "block"):
        s = sub.add_parser(name)
        s.add_argument("--project", required=True)
        s.add_argument("--task", required=True)
        if name != "block":
            s.add_argument("--worktree", required=True)
    s = sub.choices["publish"]
    s.add_argument("--title", required=True)
    s.add_argument("--notes", required=True, help="PR body: what changed, what was/wasn't verified")
    s.add_argument("--coder", default=None, help="who actually wrote it (claude, agy, hermes)")
    sub.choices["block"].add_argument("--reason", required=True)
    a = ap.parse_args()
    return main_guard(lambda: {"prepare": cmd_prepare, "publish": cmd_publish, "block": cmd_block}[a.cmd](a))


if __name__ == "__main__":
    raise SystemExit(main())
