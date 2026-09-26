"""Shared helpers for the Mercury scripts that Hermes runs.

These scripts are the deterministic hands of the Hermes orchestrator: Hermes
decides *when* to link a project, file an issue or notify the phone; the
scripts make each of those actions bounded and safe to repeat. They print one
JSON object on stdout and exit non-zero on failure, so an agent can read them.

Paths never come from $HOME: kanban workers run with a per-profile HOME, which
hides the real ~/.hermes, `gh` login and Claude Code login (Phase 0 finding).
"""
from __future__ import annotations

import hashlib
import json
import os
import pwd
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REAL_HOME = Path(os.environ.get("MERCURY_REAL_HOME") or pwd.getpwuid(os.getuid()).pw_dir)
HERMES_ROOT = Path(os.environ.get("MERCURY_HERMES_ROOT") or REAL_HOME / ".hermes")
MERCURY_HOME = Path(os.environ.get("MERCURY_HOME") or HERMES_ROOT / "mercury")
REGISTRY = MERCURY_HOME / "projects.json"
TASKS_DIR = MERCURY_HOME / "tasks"
FILED = MERCURY_HOME / "filed.json"

GH = os.environ.get("MERCURY_GH") or "gh"
HERMES = os.environ.get("MERCURY_HERMES_BIN") or str(REAL_HOME / ".local" / "bin" / "hermes")

CODERS = ("claude", "agy")
_SLUG_RE = re.compile(r"[^a-z0-9]+")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


class MercuryError(Exception):
    pass


def slug(text: str, limit: int = 40) -> str:
    return _SLUG_RE.sub("-", text.lower()).strip("-")[:limit].strip("-") or "x"


def real_env(extra: dict | None = None) -> dict:
    """Environment for gh/git/coders: the real HOME, so their logins are found."""
    env = dict(os.environ)
    env["HOME"] = str(REAL_HOME)
    env.setdefault("GH_CONFIG_DIR", str(REAL_HOME / ".config" / "gh"))
    if extra:
        env.update(extra)
    return env


def run(cmd: list[str], *, cwd: str | Path | None = None, env: dict | None = None,
        timeout: int = 120, check: bool = True, input: str | None = None) -> subprocess.CompletedProcess:
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env or real_env(), capture_output=True, text=True,
                           timeout=timeout, input=input)
    except FileNotFoundError as exc:
        raise MercuryError(f"not found: {cmd[0]}") from exc
    except subprocess.TimeoutExpired as exc:
        raise MercuryError(f"timed out after {timeout}s: {' '.join(cmd[:3])}") from exc
    if check and p.returncode != 0:
        tail = (p.stderr or p.stdout or "").strip().splitlines()[-3:]
        raise MercuryError(f"{' '.join(cmd[:3])} failed ({p.returncode}): {' | '.join(tail)}")
    return p


def gh(*args: str, timeout: int = 60, check: bool = True, input: str | None = None) -> subprocess.CompletedProcess:
    return run([GH, *args], timeout=timeout, check=check, input=input)


def hermes(*args: str, timeout: int = 120, check: bool = True) -> subprocess.CompletedProcess:
    return run([HERMES, *args], timeout=timeout, check=check)


# -- JSON files -------------------------------------------------------------------
def read_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def write_json(path: Path, data) -> None:
    """Atomic: a crash mid-write never leaves half a registry behind."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


# -- registry ---------------------------------------------------------------------
def load_projects() -> list[dict]:
    return read_json(REGISTRY, {"projects": []}).get("projects", [])


def save_projects(projects: list[dict]) -> None:
    write_json(REGISTRY, {"projects": sorted(projects, key=lambda p: p["id"])})


def get_project(project_id: str) -> dict:
    for p in load_projects():
        if p["id"] == project_id or p["repo"].lower() == project_id.lower():
            return p
    raise MercuryError(f"unknown project: {project_id}")


# -- per-task state (read by the bridge's Work view) ------------------------------
def task_state(task_id: str) -> dict:
    return read_json(TASKS_DIR / f"{task_id}.json", {})


def update_task_state(task_id: str, **fields) -> dict:
    state = task_state(task_id)
    state.update({k: v for k, v in fields.items() if v is not None})
    state["task"] = task_id
    state["updatedAt"] = time.time()
    write_json(TASKS_DIR / f"{task_id}.json", state)
    return state


def all_task_states() -> list[dict]:
    if not TASKS_DIR.is_dir():
        return []
    return [read_json(p, {}) for p in sorted(TASKS_DIR.glob("t_*.json"))]


def draft_key(project_id: str, title: str, body: str) -> str:
    return hashlib.sha256(f"{project_id}\0{title.strip()}\0{body.strip()}".encode()).hexdigest()[:24]


# -- output -----------------------------------------------------------------------
def emit(obj: dict, code: int = 0) -> int:
    print(json.dumps(obj, indent=2, sort_keys=True))
    return code


def main_guard(fn) -> int:
    try:
        return fn()
    except MercuryError as exc:
        return emit({"ok": False, "error": str(exc)}, 1)


def die_usage(msg: str) -> None:
    print(json.dumps({"ok": False, "error": msg}), file=sys.stdout)
    raise SystemExit(2)
