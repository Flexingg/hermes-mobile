#!/usr/bin/env python3
"""Follow Mercury PRs to "ready for testing" (a Hermes `--no-agent` cron job).

    mercury_ci.py            # report
    mercury_ci.py --apply    # act: fetch APK, notify, send red CI back once

For every task in review: CI green (or no CI) -> download the APK artifact of
the PR head's run when there is one, then notify "ready for testing" once per
head commit. CI red -> send the task back to its worker
with the failing checks, once per task; red again after that -> "needs you". Merged or closed
PRs are recorded and dropped. One line per change; silent otherwise.
"""
from __future__ import annotations

import argparse
import json
import shutil
import tempfile
import time
from pathlib import Path

from mercury_common import (MERCURY_HOME, MercuryError, all_task_states, get_project, gh, hermes,
                            run, task_state, update_task_state)
from mercury_notify import notify

APKS = MERCURY_HOME / "apks"
FOLLOWED = ("review", "ci_retry")
RED = {"FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"}


def ci_summary(rollup: list[dict]) -> tuple[str, list[str]]:
    """green | red | pending | none, plus the names of failing checks."""
    if not rollup:
        return "none", []
    failing, pending = [], False
    for c in rollup:
        name = c.get("name") or c.get("context") or "check"
        status = (c.get("status") or "").upper()
        conclusion = (c.get("conclusion") or c.get("state") or "").upper()
        if status and status != "COMPLETED":
            pending = True
        elif conclusion in RED:
            failing.append(name)
        elif conclusion in ("PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS"):
            pending = True
    if failing:
        return "red", failing
    return ("pending", []) if pending else ("green", [])


def fetch_apk(project: dict, head_sha: str, pr: int) -> str | None:
    """The debug APK built for this exact commit, if CI produced one."""
    runs = json.loads(gh("run", "list", "-R", project["repo"], "--commit", head_sha, "--json",
                         "databaseId,status,conclusion", check=False).stdout or "[]")
    for run in runs:
        if run.get("status") != "completed" or run.get("conclusion") != "success":
            continue
        arts = json.loads(gh("api", f"repos/{project['repo']}/actions/runs/{run['databaseId']}/artifacts",
                             check=False).stdout or "{}").get("artifacts", [])
        for art in arts:
            if "apk" not in art.get("name", "").lower() or art.get("expired"):
                continue
            with tempfile.TemporaryDirectory() as tmp:
                gh("run", "download", str(run["databaseId"]), "-R", project["repo"], "-n", art["name"],
                   "-D", tmp, timeout=600)
                apks = sorted(Path(tmp).rglob("*.apk"))
                if not apks:
                    continue
                dest = APKS / project["id"] / f"pr{pr}-{head_sha[:7]}.apk"
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(apks[0], dest)
                return str(dest)
    return None


def cleanup(project: dict, task: str, branch: str | None) -> list[str]:
    """The work is in: drop this task's worktree and both copies of its branch.

    Best-effort and reported. A leftover worktree or branch is not worth failing
    the run over, but it must not be silent either — each line names what went.
    """
    done = []
    wt = task_state(task).get("worktree")
    if wt and Path(wt).is_dir():
        if run(["git", "-C", project["path"], "worktree", "remove", "--force", wt],
               check=False, timeout=120).returncode == 0:
            done.append(f"worktree {wt}")
    run(["git", "-C", project["path"], "worktree", "prune"], check=False)
    if branch:
        if run(["git", "-C", project["path"], "branch", "-D", branch],
               check=False, timeout=60).returncode == 0:
            done.append(f"branch {branch}")
        if gh("api", "-X", "DELETE", f"repos/{project['repo']}/git/refs/heads/{branch}",
              check=False, timeout=60).returncode == 0:
            done.append(f"remote branch {branch}")
    return done


def finish(project: dict, task: str, pr: int, view: dict, head: str, apply: bool) -> str:
    """The PR is over: close the task out, tell the phone, clean up.

    Merged -> the task is done, the worktree and branch go, the phone gets one
    push. Closed without merging -> recorded and reported the same way, but the
    branch is left alone: nothing landed, so nothing is safe to delete.
    """
    state = task_state(task)
    merged = view.get("state") == "MERGED"
    label = f"{project['id']} #{state.get('issue')} PR #{pr}"
    if not apply:
        return f"would close {label} ({view['state'].lower()})"
    url = view.get("url")
    title = view.get("title", "")
    update_task_state(task, phase="merged" if merged else "closed", headSha=head,
                      mergedAt=time.time() if merged else None)
    note = f"PR #{pr} {'merged' if merged else 'closed without merging'}: {url or ''}".strip()
    hermes("kanban", "--board", project["board"], "comment", task, note, check=False)
    hermes("kanban", "--board", project["board"], "complete", task, "--result", note, check=False)
    if merged:
        gone = cleanup(project, task, state.get("branch"))
        r = notify("merged", project["id"], f"{project['name']} #{state.get('issue')} merged",
                   title, task=task, url=url)
        return (f"closed {label} (merged)"
                f"{' · cleaned ' + ', '.join(gone) if gone else ''}"
                f"{' (already notified)' if r.get('skipped') else ''}")
    notify("info", project["id"], f"{project['name']} #{state.get('issue')} closed without merging",
           title, task=task, url=url)
    return f"closed {label} (not merged — branch kept)"


def follow(state: dict, apply: bool) -> str | None:
    project = get_project(state["project"])
    task, pr = state["task"], state["prNumber"]
    view = json.loads(gh("pr", "view", str(pr), "-R", project["repo"], "--json",
                         "state,headRefOid,statusCheckRollup,url,title").stdout)
    head = view.get("headRefOid") or ""
    if view.get("state") in ("MERGED", "CLOSED"):
        return finish(project, task, pr, view, head, apply)
    ci, failing = ci_summary(view.get("statusCheckRollup") or [])
    if ci == "pending" or (ci == state.get("ci") and head == state.get("headSha")):
        return None
    label = f"{project['id']} #{state.get('issue')} PR #{pr}"
    if ci in ("green", "none"):
        if not apply:
            return f"would mark ready: {label} (CI {ci})"
        apk = fetch_apk(project, head, pr) if ci == "green" else None
        if apk is None and state.get("localApkSha") == head:
            apk = state.get("localApk")  # built by the gates on this machine, same commit
        update_task_state(task, ci=ci, headSha=head, apk=apk, phase="ready")
        r = notify("ready", project["id"], f"{project['name']} #{state.get('issue')} ready for testing",
                   view.get("title", ""), task=task, url=view.get("url"), apk=apk)
        return f"ready: {label}{' with APK' if apk else ''}{' (already notified)' if r.get('skipped') else ''}"
    # red
    if not apply:
        return f"would handle red CI: {label}: {', '.join(failing)}"
    # one automatic retry per task, whatever commit the fix lands on
    if not state.get("ciRetriedSha"):
        hermes("kanban", "--board", project["board"], "comment", task,
               f"CI failed on {head[:7]}: {', '.join(failing)}. Fix it on the same branch and publish "
               "again (mercury_ship.py publish reuses the open PR).")
        hermes("kanban", "--board", project["board"], "reopen-review", task, check=False)
        update_task_state(task, ci="red", headSha=head, ciRetriedSha=head, phase="ci_retry",
                          failingChecks=failing)
        return f"sent back to the worker: {label}: {', '.join(failing)}"
    update_task_state(task, ci="red", headSha=head, phase="needs_you", failingChecks=failing)
    notify("needs_you", project["id"], f"{project['name']} #{state.get('issue')} needs you",
           f"CI still failing: {', '.join(failing)}", task=task, url=view.get("url"))
    return f"needs you: {label}: {', '.join(failing)}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()
    failed = False
    for state in all_task_states():
        if state.get("phase") not in FOLLOWED or not state.get("prNumber"):
            continue
        try:
            line = follow(state, a.apply)
        except MercuryError as exc:
            failed, line = True, f"error {state.get('task')}: {exc}"
        if line:
            print(line)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
