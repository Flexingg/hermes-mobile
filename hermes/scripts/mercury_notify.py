#!/usr/bin/env python3
"""Tell the phone something (run by Hermes). The only way anything reaches Mercury.

    mercury_notify.py --kind ready --project lumen-launcher --task t_ab12 \
        --title "lumen-launcher #42 ready for testing" --body "Add fasting card" --url PR_URL [--apk PATH]

Kinds: ready | needs_you | working | info. POSTs to the bridge's loopback-only
/internal/notify, authenticated with ~/.hermes/mercury/notify.key (created by
install.sh; the bridge reads the same file). The bridge turns it into an FCM push
and a live event for the app. `ready` and `needs_you` are sent once per task and
PR head: a repeat is reported as skipped, not pushed twice.
"""
from __future__ import annotations

import argparse
import json
import os
import urllib.error
import urllib.request

from mercury_common import MERCURY_HOME, MercuryError, emit, main_guard, task_state, update_task_state

BRIDGE = os.environ.get("MERCURY_BRIDGE_URL", "http://127.0.0.1:9130").rstrip("/")
KEY_FILE = MERCURY_HOME / "notify.key"
KINDS = ("ready", "needs_you", "working", "info")


def send(payload: dict) -> dict:
    try:
        key = KEY_FILE.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise MercuryError(f"{KEY_FILE} is missing: run hermes/install.sh") from exc
    req = urllib.request.Request(f"{BRIDGE}/internal/notify", method="POST",
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json", "X-Mercury-Notify-Key": key})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as exc:
        raise MercuryError(f"bridge refused the notification: HTTP {exc.code}") from exc
    except OSError as exc:
        raise MercuryError(f"bridge unreachable at {BRIDGE}: {exc}") from exc


def notify(kind: str, project: str, title: str, body: str = "", task: str | None = None,
           url: str | None = None, apk: str | None = None, force: bool = False) -> dict:
    if kind not in KINDS:
        raise MercuryError(f"kind must be one of {', '.join(KINDS)}")
    once_key = None
    if task and kind in ("ready", "needs_you"):
        state = task_state(task)
        once_key = f"{kind}:{state.get('prNumber')}:{state.get('headSha')}"
        if not force and once_key in (state.get("notified") or []):
            return {"skipped": "already sent", "key": once_key}
    result = send({"kind": kind, "project": project, "task": task, "title": title, "body": body,
                   "url": url, "apk": apk})
    if once_key:
        state = task_state(task)
        update_task_state(task, notified=(state.get("notified") or []) + [once_key])
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kind", required=True, choices=KINDS)
    ap.add_argument("--project", required=True)
    ap.add_argument("--title", required=True)
    ap.add_argument("--body", default="")
    ap.add_argument("--task")
    ap.add_argument("--url")
    ap.add_argument("--apk")
    ap.add_argument("--force", action="store_true", help="send even if already sent")
    a = ap.parse_args()
    return main_guard(lambda: emit({"ok": True, **notify(a.kind, a.project, a.title, a.body, a.task,
                                                          a.url, a.apk, a.force)}))


if __name__ == "__main__":
    raise SystemExit(main())
