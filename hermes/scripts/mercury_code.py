#!/usr/bin/env python3
"""Run the project's coder in a task worktree, then its gates (run by a Hermes worker).

    mercury_code.py run   --project lumen-launcher --worktree DIR --brief brief.md [--max-turns 40]
    mercury_code.py gates --project lumen-launcher --worktree DIR

Wraps Hermes' own ~/.hermes/scripts/code_task.py, adding what a kanban worker
can't be trusted to remember:
  * the real HOME, so Claude Code / agy / gh find their logins (workers get a
    per-profile HOME);
  * an environment scrubbed of tokens and keys, so a coder never sees them;
  * a guard that the coder stayed on the task branch and did not rewrite history;
  * the project's gates run here, with the result in the JSON, never taken from
    the coder's own report.

coderStatus: done | incomplete (cut off: usage limit, max turns) |
unavailable (no usable coder; the worker codes it itself) | failed.
"""
from __future__ import annotations

import argparse
import os
import re
from pathlib import Path

from mercury_common import HERMES_ROOT, REAL_HOME, MercuryError, emit, get_project, main_guard, real_env, run

CODE_TASK = HERMES_ROOT / "scripts" / "code_task.py"
_SECRET_NAME = re.compile(r"(TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|_KEY$|CREDENTIAL)", re.I)
# Things a coder may leave in a worktree that must never be committed.
NEVER_COMMIT = re.compile(r"(^|/)(data/(transactions|rules|config|categories|accounts|budgets|goals)\.json"
                          r"|\.env(\..*)?|.*\.har|secrets?/.*|.*\.jks|.*\.keystore|key\.properties"
                          r"|local\.properties)$")


# Per-user toolchains a login shell doesn't put on PATH here (flutter lives in
# ~/dev/flutter): without them a Flutter repo's gates fail with "not found".
TOOL_DIRS = ("dev/flutter/bin", "flutter/bin", ".local/bin", ".pub-cache/bin")


def coder_env() -> dict:
    env = real_env()
    for name in list(env):
        if _SECRET_NAME.search(name):
            del env[name]
    path = env.get("PATH", "").split(os.pathsep) if env.get("PATH") else []
    for rel in TOOL_DIRS:
        d = str(REAL_HOME / rel)
        if Path(d).is_dir() and d not in path:
            path.append(d)
    env["PATH"] = os.pathsep.join(path)
    return env


def git(worktree: Path, *args: str, check: bool = True) -> str:
    return (run(["git", "-C", str(worktree), *args], check=check, timeout=60).stdout or "").strip()


def changed_files(worktree: Path) -> list[str]:
    """Paths the task changed, tracked or new. -z: no quoting, no trimming (a
    porcelain line starts with a status column that may be a space)."""
    raw = run(["git", "-C", str(worktree), "status", "--porcelain", "-z", "--untracked-files=all"],
              timeout=60).stdout or ""
    entries = raw.split("\0")
    out, i = [], 0
    while i < len(entries):
        entry = entries[i]
        i += 1
        if len(entry) < 4:
            continue
        status, path = entry[:2], entry[3:]
        if status[0] in "RC":
            i += 1  # the next field is the rename/copy source
        out.append(path)
    return out


def run_gates(project: dict, worktree: Path) -> dict:
    cmd = (project.get("gates") or "").strip()
    if not cmd:
        return {"cmd": "", "rc": None, "passed": None, "tail": "no gates configured"}
    p = run(["bash", "-lc", cmd], cwd=worktree, env=coder_env(), timeout=45 * 60, check=False)
    tail = "\n".join(((p.stdout or "") + (p.stderr or "")).strip().splitlines()[-40:])
    return {"cmd": cmd, "rc": p.returncode, "passed": p.returncode == 0, "tail": tail}


def cmd_run(a) -> int:
    project = get_project(a.project)
    worktree = Path(a.worktree).resolve()
    brief = Path(a.brief).resolve()
    if not (worktree / ".git").exists():
        raise MercuryError(f"{worktree} is not a git worktree")
    if not brief.is_file():
        raise MercuryError(f"no brief at {brief}")
    if not CODE_TASK.exists():
        raise MercuryError(f"{CODE_TASK} is missing")
    coder = project.get("coder", "claude")
    branch = git(worktree, "rev-parse", "--abbrev-ref", "HEAD")
    head = git(worktree, "rev-parse", "HEAD")
    if branch in ("HEAD", project.get("defaultBranch", "main")):
        raise MercuryError(f"refusing to code on {branch!r}: the task must be on its own branch")

    cmd = ["python3", str(CODE_TASK), "--agent", coder, "-C", str(worktree), "-f", str(brief),
           "-n", str(a.max_turns)]
    if coder == "agy":
        cmd += ["--timeout-min", str(a.timeout_min)]
    p = run(cmd, env=coder_env(), timeout=(a.timeout_min + 10) * 60, check=False)
    out = (p.stdout or "") + (p.stderr or "")
    report = out.split("--- agent report (NOT evidence) ---", 1)[-1].strip()[:2000]
    m = re.search(r"'session_id': '([^']+)'", out)
    if p.returncode == 3 or "no usable coding agent" in out:
        status = "unavailable"
    elif p.returncode == 2 or "[delegate] INCOMPLETE" in out:
        limit = re.search(r"(session|usage|rate) limit|hit your limit", out, re.I)
        status = "unavailable" if limit else "incomplete"
    elif p.returncode == 0:
        status = "done"
    else:
        status = "failed"

    branch_after = git(worktree, "rev-parse", "--abbrev-ref", "HEAD")
    ancestor = run(["git", "-C", str(worktree), "merge-base", "--is-ancestor", head, "HEAD"],
                   check=False, timeout=30).returncode == 0
    branch_ok = branch_after == branch and ancestor
    changed = changed_files(worktree)
    blocked = [f for f in changed if NEVER_COMMIT.search(f)]
    gates = run_gates(project, worktree) if branch_ok else {"cmd": project.get("gates", ""), "rc": None,
                                                            "passed": False, "tail": "skipped: branch guard failed"}
    ok = status == "done" and branch_ok and gates["passed"] is not False
    return emit({"ok": ok, "coder": coder, "coderStatus": status, "coderExit": p.returncode,
                 "sessionId": m.group(1) if m else None, "report": report,
                 "branch": branch, "branchOk": branch_ok,
                 "branchProblem": None if branch_ok else (
                     f"coder moved to {branch_after!r}" if branch_after != branch else "history was rewritten"),
                 "changed": changed, "neverCommit": blocked, "gates": gates}, 0 if ok else 1)


def cmd_gates(a) -> int:
    project = get_project(a.project)
    gates = run_gates(project, Path(a.worktree).resolve())
    return emit({"ok": gates["passed"] is not False, "gates": gates}, 0 if gates["passed"] is not False else 1)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("run")
    s.add_argument("--project", required=True)
    s.add_argument("--worktree", required=True)
    s.add_argument("--brief", required=True)
    s.add_argument("--max-turns", type=int, default=40)
    s.add_argument("--timeout-min", type=int, default=50)
    s = sub.add_parser("gates")
    s.add_argument("--project", required=True)
    s.add_argument("--worktree", required=True)
    a = ap.parse_args()
    return main_guard(lambda: {"run": cmd_run, "gates": cmd_gates}[a.cmd](a))


if __name__ == "__main__":
    raise SystemExit(main())
