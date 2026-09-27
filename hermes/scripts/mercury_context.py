#!/usr/bin/env python3
"""The per-project context digest: the short, hand-written brief a task starts from.

    mercury_context.py show --project lumen-launcher   # the digest, as plain text
    mercury_context.py set  --project lumen-launcher --file digest.md
    mercury_context.py set  --project lumen-launcher --text "..."
    mercury_context.py list                            # which projects have one

Why this exists: `ship-issue` used to tell every worker to read the repo's
`AGENTS.md` / `CLAUDE.md` / `README`. Most repos have no AGENTS.md, so the worker
read the README — 19 KB in this repo, several thousand tokens per task, every
task. The digest is the same knowledge compressed to what a task actually needs
(build and test commands, layout, conventions, traps), written ONCE per project,
and read by every worker instead of the README.

It is not generated here: writing it needs a model, so the orchestrator writes it
once after linking a repo and stores it with `set`. This script only stores,
bounds, and prints it, so a model's output can never grow the file unbounded.

`show` prints the digest itself (plain text, no JSON envelope) — this is the one
script whose whole purpose is to put text in front of an agent, and an envelope
around it is tokens spent for nothing. It exits 1 with a JSON error when the
project has no digest yet, which is the worker's cue to fall back to the repo.
"""
from __future__ import annotations

import argparse
from pathlib import Path

from mercury_common import MERCURY_HOME, MercuryError, emit, get_project, main_guard

CONTEXT_DIR = MERCURY_HOME / "context"
# A digest that is not short has stopped being a token saving and become the
# README again. Refuse rather than store it.
MAX_CHARS = 8000


def digest_path(project_id: str) -> Path:
    return CONTEXT_DIR / f"{project_id}.md"


def read_digest(project_id: str) -> str:
    try:
        return digest_path(project_id).read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def cmd_show(a) -> int:
    project = get_project(a.project)
    text = read_digest(project["id"])
    if not text:
        raise MercuryError(
            f"no context digest for {project['id']} yet. Read the repo's AGENTS.md/CLAUDE.md "
            f"instead, and ask the orchestrator to write one: mercury_context.py set "
            f"--project {project['id']} --file <digest.md>")
    print(text)
    return 0


def cmd_set(a) -> int:
    project = get_project(a.project)
    if bool(a.file) == bool(a.text):
        raise MercuryError("give exactly one of --file or --text")
    raw = Path(a.file).read_text(encoding="utf-8") if a.file else a.text
    text = (raw or "").strip()
    if not text:
        raise MercuryError("the digest is empty")
    if len(text) > MAX_CHARS:
        raise MercuryError(f"the digest is {len(text)} chars; the limit is {MAX_CHARS} "
                           f"(compress it — a digest that is not short saves nothing)")
    CONTEXT_DIR.mkdir(parents=True, exist_ok=True)
    dest = digest_path(project["id"])
    tmp = dest.with_suffix(".md.tmp")
    tmp.write_text(text + "\n", encoding="utf-8")
    tmp.replace(dest)
    return emit({"ok": True, "project": project["id"], "chars": len(text), "path": str(dest)})


def cmd_list(a) -> int:
    out = []
    paths = sorted(CONTEXT_DIR.glob("*.md")) if CONTEXT_DIR.is_dir() else []
    for p in paths:
        out.append({"project": p.stem, "chars": len(read_digest(p.stem))})
    return emit({"ok": True, "digests": out})


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("show")
    s.add_argument("--project", required=True)
    s = sub.add_parser("set")
    s.add_argument("--project", required=True)
    s.add_argument("--file")
    s.add_argument("--text")
    sub.add_parser("list")
    a = ap.parse_args()
    return main_guard(lambda: {"show": cmd_show, "set": cmd_set, "list": cmd_list}[a.cmd](a))


if __name__ == "__main__":
    raise SystemExit(main())
