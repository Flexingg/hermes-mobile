#!/usr/bin/env python3
"""Queue issues labelled `mercury` on GitHub (a Hermes `--no-agent` cron job).

    mercury_intake.py            # report what would change
    mercury_intake.py --apply    # queue new ones, cancel unlabelled unclaimed ones

For every linked project: an open issue labelled `mercury` with no task gets
queued (same path as Plan mode, so nothing is queued twice); a task whose issue
lost the label or was closed before a worker claimed it gets cancelled. Prints
one line per change and nothing when there is none, so the cron job stays silent.
"""
from __future__ import annotations

import argparse
import json
import sqlite3

from mercury_common import HERMES_ROOT, MercuryError, gh, hermes, load_projects, update_task_state
from mercury_issue import board_task_for, queue_issue

UNCLAIMED = ("triage", "todo", "ready", "blocked", "scheduled")


def labelled(project: dict) -> dict[int, str]:
    out = gh("issue", "list", "-R", project["repo"], "--label", "mercury", "--state", "open",
             "--limit", "100", "--json", "number,title")
    return {int(i["number"]): i["title"] for i in json.loads(out.stdout or "[]")}


def queued_unclaimed(project: dict) -> dict[int, str]:
    db = HERMES_ROOT / "kanban" / "boards" / project["board"] / "kanban.db"
    if not db.exists():
        return {}
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        rows = con.execute(
            f"SELECT id, idempotency_key FROM tasks WHERE status IN ({','.join('?' * len(UNCLAIMED))}) "
            "AND idempotency_key LIKE ?", (*UNCLAIMED, f"{project['repo']}#%")).fetchall()
    finally:
        con.close()
    out = {}
    for task_id, key in rows:
        try:
            out[int(key.rsplit("#", 1)[1])] = task_id
        except (ValueError, IndexError):
            continue
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()
    failed = False
    for project in load_projects():
        try:
            wanted = labelled(project)
            for number, title in sorted(wanted.items()):
                if board_task_for(project, number):
                    continue
                if a.apply:
                    r = queue_issue(project, number)
                    print(f"queued {project['id']} #{number} {title} -> {r['task']}")
                else:
                    print(f"would queue {project['id']} #{number} {title}")
            for number, task_id in sorted(queued_unclaimed(project).items()):
                if number in wanted:
                    continue
                if a.apply:
                    hermes("kanban", "--board", project["board"], "archive", task_id)
                    update_task_state(task_id, phase="cancelled")
                    print(f"cancelled {project['id']} #{number} ({task_id}): label removed or issue closed")
                else:
                    print(f"would cancel {project['id']} #{number} ({task_id})")
        except MercuryError as exc:
            failed = True
            print(f"error {project['id']}: {exc}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
