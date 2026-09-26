"""Fixtures for the Hermes-side Mercury scripts.

Every script runs as a subprocess, exactly as Hermes runs it, against:
  * a throwaway Hermes root (MERCURY_HERMES_ROOT) and real home (MERCURY_REAL_HOME);
  * fake `gh` and `hermes` executables that log each call and answer from canned
    responses (nothing touches GitHub or the real Hermes);
  * real git, with a local bare repo standing in for GitHub's origin.
"""
from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"

FAKE_CLI = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
d = Path(os.environ["FAKE_DIR"])
argv = sys.argv[1:]
stdin = "" if sys.stdin.isatty() else sys.stdin.read()
with open(d / "calls.jsonl", "a") as fh:
    fh.write(json.dumps({"tool": Path(sys.argv[0]).name, "argv": argv, "stdin": stdin}) + "\n")
rules = json.loads((d / "responses.json").read_text()) if (d / "responses.json").exists() else []
tool = Path(sys.argv[0]).name
best = None
for r in rules:
    m = r["match"]
    if r.get("tool", tool) == tool and argv[:len(m)] == m and (best is None or len(m) > len(best["match"])):
        best = r
if best is None:
    sys.exit(0)
for eff in best.get("effects", []):
    if eff[0] == "mkfile":
        p = Path(eff[1]); p.parent.mkdir(parents=True, exist_ok=True); p.write_text(eff[2])
sys.stdout.write(best.get("stdout", ""))
sys.stderr.write(best.get("stderr", ""))
sys.exit(best.get("rc", 0))
'''


class Env:
    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.home = tmp / "home"
        self.root = self.home / ".hermes"
        self.fake = tmp / "fake"
        self.bin = tmp / "bin"
        for d in (self.home, self.root, self.fake, self.bin, self.home / "repos"):
            d.mkdir(parents=True, exist_ok=True)
        for tool in ("gh", "hermes"):
            p = self.bin / tool
            p.write_text(FAKE_CLI)
            p.chmod(0o755)
        self.responses: list[dict] = []

    # -- fakes ---------------------------------------------------------------
    def respond(self, tool: str, match: list[str], stdout: str = "", rc: int = 0, effects=None):
        self.responses.append({"tool": tool, "match": match, "stdout": stdout, "rc": rc,
                               "effects": effects or []})
        (self.fake / "responses.json").write_text(json.dumps(self.responses))

    def calls(self, tool: str | None = None) -> list[dict]:
        f = self.fake / "calls.jsonl"
        if not f.exists():
            return []
        out = [json.loads(line) for line in f.read_text().splitlines() if line]
        return [c for c in out if tool is None or c["tool"] == tool]

    def called(self, tool: str, *prefix: str) -> list[dict]:
        return [c for c in self.calls(tool) if c["argv"][:len(prefix)] == list(prefix)]

    # -- running -------------------------------------------------------------
    def environ(self, **extra) -> dict:
        env = {k: v for k, v in os.environ.items() if not k.startswith("MERCURY_")}
        env.update({
            "MERCURY_REAL_HOME": str(self.home),
            "MERCURY_HERMES_ROOT": str(self.root),
            "MERCURY_GH": str(self.bin / "gh"),
            "MERCURY_HERMES_BIN": str(self.bin / "hermes"),
            "MERCURY_REPOS_DIR": str(self.home / "repos"),
            "FAKE_DIR": str(self.fake),
            "GIT_CONFIG_GLOBAL": str(self.tmp / "gitconfig"),
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "t@example.com",
        })
        env.update(extra)
        return env

    def run(self, script: str, *args: str, stdin: str | None = None, **extra) -> tuple[int, dict | str]:
        p = subprocess.run([sys.executable, str(SCRIPTS / script), *args], capture_output=True, text=True,
                           env=self.environ(**extra), input=stdin, timeout=120)
        try:
            return p.returncode, json.loads(p.stdout)
        except ValueError:
            return p.returncode, p.stdout + p.stderr

    # -- state helpers ---------------------------------------------------------
    def project(self, **over) -> dict:
        proj = {"id": "demo", "name": "demo", "repo": "Flexingg/demo", "path": str(self.home / "repos" / "demo"),
                "profile": "dev-demo", "board": "demo", "defaultBranch": "main", "coder": "claude",
                "gates": "true", "idleSleepMinutes": 10}
        proj.update(over)
        reg = self.root / "mercury" / "projects.json"
        reg.parent.mkdir(parents=True, exist_ok=True)
        reg.write_text(json.dumps({"projects": [proj]}))
        return proj

    def board(self, name: str = "demo") -> sqlite3.Connection:
        db = self.root / "kanban" / "boards" / name / "kanban.db"
        db.parent.mkdir(parents=True, exist_ok=True)
        con = sqlite3.connect(db)
        con.execute("CREATE TABLE IF NOT EXISTS tasks (id TEXT, status TEXT, idempotency_key TEXT, "
                    "created_at REAL)")
        return con

    def task_state(self, task: str) -> dict:
        p = self.root / "mercury" / "tasks" / f"{task}.json"
        return json.loads(p.read_text()) if p.exists() else {}


def git(cwd, *args, env=None) -> str:
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True,
                          env=env).stdout.strip()


@pytest.fixture
def env(tmp_path):
    return Env(tmp_path)


@pytest.fixture
def repo(env):
    """A clone of a bare 'origin', plus a task worktree on demo/t_abc-fix."""
    e = env.environ()
    origin = env.tmp / "origin.git"
    git(env.tmp, "init", "-q", "--bare", "-b", "main", str(origin), env=e)
    main = env.home / "repos" / "demo"
    git(env.tmp, "clone", "-q", str(origin), str(main), env=e)
    (main / "app.txt").write_text("v1\n")
    (main / ".gitignore").write_text("")
    git(main, "add", "-A", env=e)
    git(main, "commit", "-qm", "init", env=e)
    git(main, "push", "-q", "origin", "main", env=e)
    wt = env.tmp / "wt"
    git(main, "worktree", "add", "-q", "-b", "demo/t_abc-fix", str(wt), env=e)
    return {"origin": origin, "main": main, "wt": wt, "env": e}
