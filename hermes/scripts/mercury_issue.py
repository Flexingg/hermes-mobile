#!/usr/bin/env python3
"""File issues and queue them for the project's agent (run by Hermes).

    mercury_issue.py file  --project lumen-launcher --draft draft.json   # or --draft - (stdin)
    mercury_issue.py queue --project lumen-launcher --issue 42
    mercury_issue.py cancel --project lumen-launcher --issue 42

`file` turns a Plan-mode draft ({"title", "body", "acceptance": [...], "labels": [...]})
into a GitHub issue labelled `mercury`, then queues it. `queue` puts an existing open
issue on the project's kanban board as a worktree task for the project's profile,
running the `ship-issue` skill. Both are idempotent: the same draft files one issue,
and one issue is queued once (kanban idempotency key `<repo>#<n>`). `cancel`
archives the task if no worker has claimed it yet.
"""
from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
from pathlib import Path

from mercury_common import (FILED, HERMES_ROOT, MercuryError, draft_key, emit, get_project, gh, hermes,
                            main_guard, read_json, update_task_state, write_json)

MAX_TITLE = 200
MAX_BODY = 20000
TASK_RUNTIME = "2h"
_ISSUE_URL_RE = re.compile(r"https://github\.com/[^/\s]+/[^/\s]+/issues/(\d+)")


def load_draft(src: str) -> dict:
    raw = sys.stdin.read() if src == "-" else Path(src).read_text(encoding="utf-8")
    try:
        draft = json.loads(raw)
    except ValueError as exc:
        raise MercuryError(f"draft is not JSON: {exc}") from exc
    if not isinstance(draft, dict):
        raise MercuryError("draft must be a JSON object")
    title = str(draft.get("title") or "").strip()
    if not title:
        raise MercuryError("draft has no title")
    if len(title) > MAX_TITLE:
        raise MercuryError(f"title is longer than {MAX_TITLE} characters")
    body = str(draft.get("body") or "").strip()
    acceptance = [str(x).strip() for x in (draft.get("acceptance") or []) if str(x).strip()]
    labels = [str(x).strip() for x in (draft.get("labels") or []) if str(x).strip()]
    if acceptance:
        body += "\n\n**Acceptance criteria**\n" + "\n".join(f"- [ ] {c}" for c in acceptance)
    if len(body) > MAX_BODY:
        raise MercuryError(f"body is longer than {MAX_BODY} characters")
    return {"title": title, "body": body, "labels": labels}


def existing_labels(repo: str) -> set[str]:
    out = gh("label", "list", "-R", repo, "--limit", "200", "--json", "name", check=False)
    try:
        return {x["name"] for x in json.loads(out.stdout or "[]")}
    except ValueError:
        return set()


def board_task_for(project: dict, number: int) -> dict | None:
    """Read-only lookup of the task queued for an issue (by its idempotency key)."""
    db = HERMES_ROOT / "kanban" / "boards" / project["board"] / "kanban.db"
    if not db.exists():
        return None
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        row = con.execute(
            "SELECT id, status FROM tasks WHERE idempotency_key=? AND status != 'archived' "
            "ORDER BY created_at DESC LIMIT 1", (f"{project['repo']}#{number}",)).fetchone()
    finally:
        con.close()
    return {"id": row[0], "status": row[1]} if row else None


def task_body(project: dict, issue: dict) -> str:
    text = (issue.get("body") or "").strip()
    if len(text) > 6000:
        text = text[:6000] + "\n\n[issue text truncated; read the rest with gh issue view]"
    gates = project.get("gates") or "(none configured: say so in the PR)"
    return (
        f"Ship GitHub issue {project['repo']}#{issue['number']}: {issue['title']}\n"
        f"{issue['url']}\n\n"
        f"Follow the `ship-issue` skill exactly.\n"
        f"- project: {project['id']}\n"
        f"- repo: {project['repo']} (default branch {project.get('defaultBranch', 'main')})\n"
        f"- coder: {project.get('coder', 'claude')} (fallback: you, Hermes)\n"
        f"- gates: {gates}\n\n"
        f"Issue text:\n{text or '(empty)'}\n"
    )


def queue_issue(project: dict, number: int) -> dict:
    info = gh("issue", "view", str(number), "-R", project["repo"], "--json",
              "number,title,url,state,body")
    issue = json.loads(info.stdout)
    if issue.get("state") != "OPEN":
        raise MercuryError(f"{project['repo']}#{number} is {issue.get('state', '?').lower()}, not open")
    existing = board_task_for(project, number)
    if existing:
        return {"task": existing["id"], "status": existing["status"], "alreadyQueued": True,
                "issue": number, "url": issue["url"]}
    title = f"#{number} {issue['title']}"[:180]
    out = hermes("kanban", "--board", project["board"], "create", title,
                 "--body", task_body(project, issue),
                 "--assignee", project["profile"],
                 "--project", project["id"],
                 "--workspace", "worktree",
                 "--idempotency-key", f"{project['repo']}#{number}",
                 "--max-runtime", TASK_RUNTIME,
                 "--skill", "ship-issue",
                 "--created-by", "mercury",
                 "--json")
    try:
        task = json.loads(out.stdout[out.stdout.index("{"):])
    except ValueError as exc:
        raise MercuryError(f"could not read the created task: {out.stdout[-300:]}") from exc
    update_task_state(task["id"], project=project["id"], repo=project["repo"], issue=number,
                      issueUrl=issue["url"], title=issue["title"], branch=task.get("branch_name"),
                      coder=project.get("coder", "claude"), phase="queued")
    return {"task": task["id"], "status": task.get("status"), "alreadyQueued": False,
            "issue": number, "url": issue["url"], "branch": task.get("branch_name")}


def cmd_file(a) -> int:
    project = get_project(a.project)
    draft = load_draft(a.draft)
    key = draft_key(project["id"], draft["title"], draft["body"])
    filed = read_json(FILED, {})
    if key in filed:
        number = filed[key]["issue"]
        return emit({"ok": True, "duplicateDraft": True, **queue_issue(project, number)})
    labels = ["mercury"] + [x for x in draft["labels"] if x in existing_labels(project["repo"])]
    args = ["issue", "create", "-R", project["repo"], "--title", draft["title"], "--body-file", "-"]
    for label in dict.fromkeys(labels):
        args += ["--label", label]
    out = gh(*args, input=draft["body"] or " ")
    m = _ISSUE_URL_RE.search(out.stdout or "")
    if not m:
        raise MercuryError(f"gh did not return an issue URL: {(out.stdout or '')[-200:]}")
    number = int(m.group(1))
    filed[key] = {"project": project["id"], "issue": number, "url": m.group(0)}
    write_json(FILED, filed)
    return emit({"ok": True, "duplicateDraft": False, **queue_issue(project, number)})


def cmd_queue(a) -> int:
    return emit({"ok": True, **queue_issue(get_project(a.project), a.issue)})


def cmd_cancel(a) -> int:
    project = get_project(a.project)
    task = board_task_for(project, a.issue)
    if not task:
        return emit({"ok": True, "cancelled": False, "reason": "no queued task for that issue"})
    if task["status"] not in ("triage", "todo", "ready", "blocked", "scheduled"):
        return emit({"ok": True, "cancelled": False, "task": task["id"],
                     "reason": f"a worker already has it (status {task['status']})"})
    hermes("kanban", "--board", project["board"], "archive", task["id"])
    update_task_state(task["id"], phase="cancelled")
    return emit({"ok": True, "cancelled": True, "task": task["id"]})


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("file")
    s.add_argument("--project", required=True)
    s.add_argument("--draft", required=True, help="path to the draft JSON, or - for stdin")
    for name in ("queue", "cancel"):
        s = sub.add_parser(name)
        s.add_argument("--project", required=True)
        s.add_argument("--issue", required=True, type=int)
    a = ap.parse_args()
    return main_guard(lambda: {"file": cmd_file, "queue": cmd_queue, "cancel": cmd_cancel}[a.cmd](a))


if __name__ == "__main__":
    raise SystemExit(main())
