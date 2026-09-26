#!/usr/bin/env python3
"""Agent processes and memory, and the hard RAM floor (run by Hermes).

    mercury_resources.py snapshot            # JSON: free RAM + agent processes
    mercury_resources.py enforce [--floor-mb 1536] [--dry-run]   # `--no-agent` cron job

`enforce` is deliberately narrow. It only ever stops a coder process (claude/agy)
that it can trace to a code_task.py run, newest first, and only while
MemAvailable is under the floor. Never touched, whatever the pressure: the
gateway, the bridge, `agy remote-control`, and interactive `claude` sessions.
Concurrency is capped by Hermes itself (kanban.max_in_progress), not here.
Prints one line per action; silent otherwise.
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import time
from pathlib import Path

PROC = Path(os.environ.get("MERCURY_PROC", "/proc"))
DEFAULT_FLOOR_MB = 1536


def mem_available_mb() -> int:
    for line in (PROC / "meminfo").read_text().splitlines():
        if line.startswith("MemAvailable:"):
            return int(line.split()[1]) // 1024
    return 0


def _cmdline(pid: int) -> list[str]:
    try:
        raw = (PROC / str(pid) / "cmdline").read_bytes()
    except OSError:
        return []
    return [p.decode("utf-8", "replace") for p in raw.split(b"\0") if p]


def _stat(pid: int) -> tuple[int, int, int]:
    """(ppid, rss_mb, start_ticks)"""
    try:
        fields = (PROC / str(pid) / "stat").read_text().rsplit(")", 1)[1].split()
        rss_pages = int(fields[21])
        return int(fields[1]), rss_pages * os.sysconf("SC_PAGE_SIZE") // (1024 * 1024), int(fields[19])
    except (OSError, IndexError, ValueError):
        return 0, 0, 0


def classify(argv: list[str]) -> tuple[str, str | None]:
    """(kind, profile). kind: gateway | worker | coder | code_task | bridge | other."""
    joined = " ".join(argv)
    profile = None
    if "--profile" in argv:
        i = argv.index("--profile")
        profile = argv[i + 1] if i + 1 < len(argv) else None
    elif "-p" in argv and "hermes" in joined:
        i = argv.index("-p")
        profile = argv[i + 1] if i + 1 < len(argv) else None
    base = os.path.basename(argv[0]) if argv else ""
    if "code_task.py" in joined:
        return "code_task", profile
    if "bridge.py" in joined:
        return "bridge", None
    if "gateway" in argv and "run" in argv and ("hermes_cli.main" in joined or base == "hermes"):
        return "gateway", profile or "default"
    if base in ("claude", "claude.exe", "agy") or joined.split(" ")[0].endswith(("/claude", "/agy", "claude.exe")):
        headless = any(a in argv for a in ("-p", "--print", "--prompt"))
        return ("coder" if headless else "interactive"), None
    if "hermes" in joined and "chat" in argv:
        return "worker", profile
    return "other", profile


def processes() -> list[dict]:
    ticks = os.sysconf("SC_CLK_TCK")
    uptime = float((PROC / "uptime").read_text().split()[0])
    table = {}
    for d in PROC.iterdir():
        if not d.name.isdigit():
            continue
        pid = int(d.name)
        argv = _cmdline(pid)
        if not argv:
            continue
        ppid, rss, start = _stat(pid)
        kind, profile = classify(argv)
        table[pid] = {"pid": pid, "ppid": ppid, "kind": kind, "profile": profile, "rssMb": rss,
                      "ageSec": int(uptime - start / ticks), "cmd": " ".join(argv)[:120]}
    # a coder counts only when a code_task.py run is among its ancestors
    for p in table.values():
        if p["kind"] != "coder":
            continue
        anc, seen = table.get(p["ppid"]), 0
        while anc and seen < 20:
            if anc["kind"] == "code_task":
                p["ownedBy"] = anc["pid"]
                break
            anc, seen = table.get(anc["ppid"]), seen + 1
    return [p for p in table.values() if p["kind"] != "other"]


def cmd_snapshot(a) -> int:
    procs = processes()
    print(json.dumps({"ok": True, "memAvailableMb": mem_available_mb(), "at": time.time(),
                      "processes": sorted(procs, key=lambda p: -p["rssMb"])}, indent=2))
    return 0


def cmd_enforce(a) -> int:
    free = mem_available_mb()
    if free >= a.floor_mb:
        return 0
    victims = sorted((p for p in processes() if p["kind"] == "coder" and p.get("ownedBy")),
                     key=lambda p: p["ageSec"])  # youngest first: least work lost
    if not victims:
        print(f"low memory ({free} MB < {a.floor_mb} MB) and no coder run to stop")
        return 0
    v = victims[0]
    if a.dry_run:
        print(f"would stop coder pid {v['pid']} ({v['rssMb']} MB): {free} MB free < {a.floor_mb} MB")
        return 0
    try:
        os.kill(v["pid"], signal.SIGTERM)
    except ProcessLookupError:
        return 0
    print(f"stopped coder pid {v['pid']} ({v['rssMb']} MB, {v['ageSec']}s old): "
          f"{free} MB free < {a.floor_mb} MB. Its worker sees an incomplete run and can retry.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("snapshot")
    s = sub.add_parser("enforce")
    s.add_argument("--floor-mb", type=int, default=DEFAULT_FLOOR_MB)
    s.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    return {"snapshot": cmd_snapshot, "enforce": cmd_enforce}[a.cmd](a)


if __name__ == "__main__":
    raise SystemExit(main())
