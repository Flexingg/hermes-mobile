#!/usr/bin/env python3
"""Hermes Mobile bridge — fronts a REAL Hermes install for the Flutter app.

Serves the REST + WebSocket contract the app's `HermesRepository` expects,
reading live data straight from `~/.hermes`:
  - sessions & messages   -> state.db (SQLite)
  - model / provider      -> config.yaml
  - memory                -> memories/USER.md + memories/MEMORY.md
  - cron jobs             -> cron/jobs.json
  - skills                -> skills/**/SKILL.md
  - logs                  -> logs/*.log
  - chat (streaming)      -> real `hermes chat --resume <id>` subprocess

Run:  uvicorn bridge:app --host 0.0.0.0 --port 9130
"""
from __future__ import annotations

import asyncio
import datetime as dt
import json
import os
import re
import sqlite3
import subprocess
import threading
import time
from pathlib import Path

import psutil
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse

HERMES = Path(os.environ.get("HERMES_HOME", str(Path.home() / ".hermes")))
STATE_DB = HERMES / "state.db"
CONFIG_YAML = HERMES / "config.yaml"
MEM_DIR = HERMES / "memories"
CRON_JOBS = HERMES / "cron" / "jobs.json"
LOGS_DIR = HERMES / "logs"
SKILLS_DIR = HERMES / "skills"
PROFILES_DIR = HERMES / "profiles"

# Optional bearer token. When set, every /api/v1/* call must send it.
BRIDGE_TOKEN = os.environ.get("BRIDGE_TOKEN")
# Absolute path to the `hermes` CLI (systemd services don't inherit ~/.local/bin).
HERMES_BIN = os.environ.get("HERMES_BIN", "/home/hermes/.local/bin/hermes")

app = FastAPI(title="Hermes Mobile bridge", version="1.0")
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"]
)


@app.middleware("http")
async def auth_middleware(request: Request, call_next):
    if BRIDGE_TOKEN and request.url.path.startswith("/api/v1"):
        auth = request.headers.get("authorization", "")
        if auth != f"Bearer {BRIDGE_TOKEN}":
            return JSONResponse({"detail": "unauthorized"}, status_code=401)
    return await call_next(request)

# ---------------------------------------------------------------------------
# Chat streaming state: session_id -> list[asyncio.Queue]
# ---------------------------------------------------------------------------
_queues: dict[str, list[asyncio.Queue]] = {}
_queues_lock = threading.Lock()


def _register_queue(session_id: str, q: asyncio.Queue) -> None:
    with _queues_lock:
        _queues.setdefault(session_id, []).append(q)


def _unregister_queue(session_id: str, q: asyncio.Queue) -> None:
    with _queues_lock:
        qs = _queues.get(session_id, [])
        if q in qs:
            qs.remove(q)


def _broadcast(session_id: str, payload: dict) -> None:
    with _queues_lock:
        for q in _queues.get(session_id, []):
            try:
                q.put_nowait(payload)
            except Exception:
                pass


# ---------------------------------------------------------------------------
# Low-level helpers
# ---------------------------------------------------------------------------
def _db() -> sqlite3.Connection:
    con = sqlite3.connect(STATE_DB)
    con.row_factory = sqlite3.Row
    return con


def _now() -> float:
    return time.time()


def _iso(ts: float | None) -> str | None:
    return dt.datetime.fromtimestamp(ts).isoformat() if ts else None


def _config() -> dict:
    try:
        import yaml

        return yaml.safe_load(CONFIG_YAML.read_text()) or {}
    except Exception:
        return {}


def _model() -> dict:
    c = _config().get("model", {})
    return {"model": c.get("default", "unknown"), "provider": c.get("provider", "unknown")}


def _hash_color(s: str) -> int:
    h = 0
    for ch in s:
        h = (h * 31 + ord(ch)) & 0xFFFFFF
    return h | 0xFF000000  # opaque ARGB for Flutter Color(int)


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.get("/api/v1/status")
def status():
    m = _model()
    uptime_s = 0.0
    try:
        uptime_s = float(Path("/proc/uptime").read_text().split()[0])
    except Exception:
        pass
    h, rem = divmod(int(uptime_s), 3600)
    d, h = divmod(h, 24)
    con = _db()
    n = con.execute(
        "SELECT COUNT(*) c FROM sessions WHERE archived=0 AND hidden=0"
    ).fetchone()["c"]
    con.close()
    version = ""
    try:
        out = subprocess.run([HERMES_BIN, "--version"], capture_output=True, text=True, timeout=10)
        version = (out.stdout or out.stderr).strip().splitlines()[0]
    except Exception:
        version = "hermes"
    return {
        "cpu": psutil.cpu_percent(interval=None),
        "memory": psutil.virtual_memory().percent,
        "disk": psutil.disk_usage(str(HERMES)).percent,
        "uptime": f"{d}d {h}h {rem // 60}m",
        "gatewayUp": _gateway_up(),
        "activeSessions": n,
        "version": version,
        "fetchedAt": _iso(_now()),
    }


def _gateway_up() -> bool:
    pid_file = HERMES / "gateway.pid"
    try:
        pid = int(pid_file.read_text().strip())
        return psutil.pid_exists(pid)
    except Exception:
        return False


@app.get("/api/v1/sessions")
def sessions():
    con = _db()
    rows = con.execute(
        """SELECT id, title, display_name, last_activity_at, started_at,
                  last_activity_description, message_count, pinned, source
           FROM sessions WHERE archived=0 AND hidden=0
           ORDER BY last_activity_at DESC LIMIT 200"""
    ).fetchall()
    con.close()
    out = []
    for r in rows:
        title = r["title"] or r["display_name"] or r["source"] or "Conversation"
        ts = r["last_activity_at"] or r["started_at"] or _now()
        out.append(
            {
                "id": r["id"],
                "title": title,
                "lastPreview": (r["last_activity_description"] or "")[:140],
                "lastTimestamp": _iso(ts),
                "unreadCount": 0,
                "pinned": bool(r["pinned"]),
                "starred": False,
                "profileId": r["source"] or "hermes",
                "color": _hash_color(r["id"]),
            }
        )
    return out


@app.get("/api/v1/sessions/{session_id}/messages")
def messages(session_id: str):
    con = _db()
    rows = con.execute(
        """SELECT id, role, content, tool_name, timestamp
           FROM messages WHERE session_id=? AND active=1
           ORDER BY timestamp ASC LIMIT 500""",
        (session_id,),
    ).fetchall()
    con.close()
    out = []
    for r in rows:
        text = r["content"] or ""
        if r["role"] == "tool":
            text = _tool_text(r["content"], r["tool_name"])
        out.append(
            {
                "id": str(r["id"]),
                "sessionId": session_id,
                "role": r["role"] if r["role"] in ("user", "assistant", "system") else "tool",
                "text": text,
                "timestamp": _iso(r["timestamp"]),
                "toolName": r["tool_name"],
            }
        )
    return out


def _tool_text(content, tool_name) -> str:
    tool_name = tool_name or "tool"
    try:
        data = json.loads(content or "{}")
        if isinstance(data, dict):
            snippet = json.dumps(data)[:160]
        else:
            snippet = str(data)[:160]
    except Exception:
        snippet = (content or "")[:160]
    return f"[{tool_name}] {snippet}"


@app.post("/api/v1/sessions")
def create_session(body: dict):
    import uuid

    sid = dt.datetime.now().strftime("%Y%m%d_%H%M%S") + "_" + uuid.uuid4().hex[:6]
    title = (body.get("title") or "New conversation")[:200]
    con = _db()
    con.execute(
        """INSERT INTO sessions (id, source, title, started_at, last_activity_at,
                                 message_count, tool_call_count, archived, hidden)
           VALUES (?,?,?,?,?,0,0,0,0)""",
        (sid, body.get("profileId") or "hermes", title, _now(), _now()),
    )
    con.commit()
    con.close()
    return {
        "id": sid,
        "title": title,
        "lastPreview": "New conversation",
        "lastTimestamp": _iso(_now()),
        "unreadCount": 0,
        "pinned": False,
        "starred": False,
        "profileId": body.get("profileId") or "hermes",
        "color": _hash_color(sid),
    }


@app.post("/api/v1/chat/start")
def chat_start(body: dict):
    """Start a REAL new Hermes conversation: runs `hermes chat -q <text>` (which
    creates a genuine session), parses the returned session id, and returns it."""
    text = (body.get("text") or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="text required")
    try:
        p = subprocess.run(
            [HERMES_BIN, "chat", "-q", text, "--pass-session-id"],
            capture_output=True, text=True, timeout=180,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"hermes failed: {e}")
    out = (p.stdout or "") + "\n" + (p.stderr or "")
    m = re.search(r"Session:\s+([0-9A-Za-z_]+)", out)
    sid = m.group(1) if m else None
    tm = re.search(r"Title:\s*(.+)", out)
    title = (tm.group(1).strip() if tm else body.get("name") or text)[:200]
    if not sid:
        raise HTTPException(status_code=502, detail="could not determine new session id")
    return {
        "id": sid,
        "title": title,
        "lastPreview": text[:140],
        "lastTimestamp": _iso(_now()),
        "unreadCount": 0,
        "pinned": False,
        "starred": False,
        "profileId": "hermes",
        "color": _hash_color(sid),
    }


@app.post("/api/v1/sessions/{session_id}/messages")
def send_message(session_id: str, body: dict):
    text = (body.get("text") or "").strip()
    if not text:
        return {"ok": True, "pending": False}
    _spawn_hermes(session_id, text)
    return {"ok": True, "pending": True}


def _spawn_hermes(session_id: str, text: str) -> None:
    def run():
        cmd = [HERMES_BIN, "chat", "-q", text, "--resume", session_id]
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        if proc.stdout is not None:
            for line in proc.stdout:
                line = line.rstrip("\n")
                if line.strip():
                    _broadcast(session_id, {"event": "chunk", "delta": line + "\n"})
        proc.wait()
        _broadcast(session_id, {"event": "done"})

    t = threading.Thread(target=run, daemon=True)
    t.start()


@app.websocket("/ws/chat/{session_id}")
async def ws_chat(websocket: WebSocket, session_id: str):
    await websocket.accept()
    q: asyncio.Queue = asyncio.Queue()
    _register_queue(session_id, q)
    try:
        while True:
            payload = await q.get()
            await websocket.send_text(json.dumps(payload))
            if payload.get("event") == "done":
                break
    except WebSocketDisconnect:
        pass
    finally:
        _unregister_queue(session_id, q)


@app.post("/api/v1/sessions/{session_id}/read")
def mark_read(session_id: str):
    con = _db()
    con.execute("UPDATE sessions SET last_read_at=? WHERE id=?", (_now(), session_id))
    con.commit()
    con.close()
    return {"ok": True}


@app.post("/api/v1/sessions/{session_id}/pin")
def toggle_pin(session_id: str):
    con = _db()
    con.execute("UPDATE sessions SET pinned = 1 - pinned WHERE id=?", (session_id,))
    con.commit()
    con.close()
    return {"ok": True}


@app.post("/api/v1/sessions/{session_id}/star")
def toggle_star(session_id: str):
    return {"ok": True}


@app.delete("/api/v1/sessions/{session_id}")
def delete_session(session_id: str):
    con = _db()
    con.execute("UPDATE sessions SET hidden=1 WHERE id=?", (session_id,))
    con.commit()
    con.close()
    return {"ok": True}


# ---------------------------------------------------------------------------
# Controller: cron, skills, memory, tools, commands, webhooks
# ---------------------------------------------------------------------------
@app.get("/api/v1/cron")
def cron():
    try:
        data = json.loads(CRON_JOBS.read_text())
        jobs = data.get("jobs", [])
    except Exception:
        jobs = []
    out = []
    for j in jobs:
        sched = j.get("schedule_display") or j.get("schedule", {}).get("display") or ""
        status = "✅ Success" if j.get("state") == "scheduled" else j.get("state", "unknown")
        if j.get("no_agent"):
            status = f"script:{j.get('script', '')}"
        out.append(
            {
                "id": j.get("id"),
                "name": j.get("name", "Untitled"),
                "schedule": sched,
                "prompt": j.get("prompt") or f"script {j.get('script', '')}",
                "deliver": j.get("deliver", j.get("channel", "local")),
                "enabled": bool(j.get("enabled", True)),
                "lastRun": j.get("last_run_at"),
                "lastStatus": status,
            }
        )
    return out


@app.post("/api/v1/cron/{job_id}/run")
def run_cron(job_id: str):
    subprocess.Popen([HERMES_BIN, "cron", "run", job_id], stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL)
    return {"ok": True}


@app.get("/api/v1/skills")
def skills():
    out = []
    seen = set()
    for md in SKILLS_DIR.rglob("SKILL.md"):
        try:
            text = md.read_text(errors="ignore")[:2000]
            name = re.search(r"^name:\s*(.+)$", text, re.M)
            desc = re.search(r"^description:\s*(.+)$", text, re.M)
            n = name.group(1).strip() if name else md.parent.name
            if n in seen:
                continue
            seen.add(n)
            tags = re.findall(r"^tags:\s*\[(.*)\]$", text, re.M)
            tag_list = [t.strip().strip('"\'') for t in (tags[0].split(",") if tags else [])][:6]
            out.append(
                {
                    "id": n,
                    "name": n,
                    "description": (desc.group(1).strip() if desc else ""),
                    "tags": tag_list,
                    "enabled": True,
                }
            )
        except Exception:
            continue
    return sorted(out, key=lambda s: s["name"])


@app.get("/api/v1/memory")
def memory():
    out = []
    for fname, cat in (("USER.md", "user"), ("MEMORY.md", "memory")):
        f = MEM_DIR / fname
        if not f.exists():
            continue
        text = f.read_text(errors="ignore")
        entries = re.split(r"\n\s*§\s*\n", text)
        for i, e in enumerate(entries):
            e = e.strip()
            if e:
                out.append(
                    {"id": f"{cat}-{i}", "category": cat, "content": e,
                     "createdAt": dt.datetime.fromtimestamp(f.stat().st_mtime).isoformat()}
                )
    return out


@app.get("/api/v1/memory/search")
def memory_search(q: str = ""):
    return [m for m in memory() if q.lower() in m["content"].lower()]


@app.get("/api/v1/tools")
def tools():
    return [
        "terminal", "read_file", "write_file", "patch", "search_files",
        "web_search", "web_extract", "browser_navigate", "browser_snapshot",
        "execute_code", "delegate_task", "cronjob", "skill_manage", "memory",
        "todo", "process", "webhook",
    ]


@app.get("/api/v1/activity")
def activity(session_id: str | None = None, limit: int = 60):
    con = _db()
    if session_id:
        rows = con.execute(
            """SELECT id, session_id, tool_name, content, timestamp
               FROM messages WHERE role='tool' AND session_id=?
               ORDER BY timestamp DESC LIMIT ?""",
            (session_id, limit),
        ).fetchall()
    else:
        rows = con.execute(
            """SELECT id, session_id, tool_name, content, timestamp
               FROM messages WHERE role='tool'
               ORDER BY timestamp DESC LIMIT ?""",
            (limit,),
        ).fetchall()
    con.close()
    out = []
    for r in rows:
        status = "done"
        snippet = ""
        try:
            data = json.loads(r["content"] or "{}")
            if isinstance(data, dict):
                if data.get("error"):
                    status = "error"
                snippet = json.dumps(data)[:140]
        except Exception:
            snippet = (r["content"] or "")[:140]
        out.append({
            "id": str(r["id"]),
            "toolName": r["tool_name"] or "tool",
            "status": status,
            "detail": snippet,
            "timestamp": _iso(r["timestamp"]),
            "sessionId": r["session_id"],
        })
    return out


@app.get("/api/v1/commands")
def commands():
    return [
        {"id": "session", "label": "/session", "description": "Session management", "icon": "forum"},
        {"id": "memory", "label": "/memory", "description": "View/edit persistent memory", "icon": "memory"},
        {"id": "skills", "label": "/skills", "description": "List installed skills", "icon": "widgets"},
        {"id": "cron", "label": "/cron", "description": "Scheduled routines", "icon": "schedule"},
        {"id": "doctor", "label": "/doctor", "description": "Run health checks", "icon": "medical"},
        {"id": "model", "label": "/model", "description": "Switch active model/provider", "icon": "smart_toy"},
        {"id": "config", "label": "/config", "description": "View live configuration", "icon": "tune"},
        {"id": "status", "label": "/status", "description": "Show agent status", "icon": "monitor"},
    ]


@app.get("/api/v1/models")
def models():
    m = _model()
    return [{"provider": m["provider"], "model": m["model"], "online": True, "quotaStatus": "active"}]


@app.get("/api/v1/servers")
def servers():
    m = _model()
    bots = [{"id": "bot-hermes", "name": "@hermes",
             "description": "Default Hermes agent", "model": m["model"], "emoji": "🧠"}]
    if PROFILES_DIR.exists():
        for p in sorted(PROFILES_DIR.iterdir()):
            if p.is_dir():
                emoji = {"buff-patrick": "💪", "homie": "🏠", "boba": "🤖"}.get(p.name, "🤖")
                bots.append({"id": f"bot-{p.name}", "name": f"@{p.name}",
                             "description": f"Hermes profile: {p.name}",
                             "model": m["model"], "emoji": emoji})
    return [{
        "id": "srv-hermes",
        "name": Path(HERMES).name or "hermes",
        "baseUrl": f"bridge:{_now():.0f}",
        "isDefault": True,
        "accent": _hash_color("hermes"),
        "bots": bots,
    }]


@app.get("/api/v1/logs")
def logs(limit: int = 100):
    out = []
    files = sorted(LOGS_DIR.glob("*.log")) if LOGS_DIR.exists() else []
    if not files:
        return out
    newest = files[-1]
    lines = newest.read_text(errors="ignore").splitlines()[-int(limit):]
    for i, ln in enumerate(lines):
        if not ln.strip():
            continue
        ts = None
        m = re.match(r"^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2})", ln)
        if m:
            try:
                ts = dt.datetime.fromisoformat(m.group(1).replace(" ", "T")).isoformat()
            except Exception:
                ts = _iso(_now())
        level = "INFO"
        if "ERROR" in ln or "Traceback" in ln:
            level = "ERROR"
        elif "WARN" in ln or "warning" in ln.lower():
            level = "WARN"
        out.append({"id": f"log-{len(out)}", "level": level, "message": ln[:300],
                    "source": "gateway", "timestamp": ts or _iso(_now())})
    return out[::-1]


@app.get("/api/v1/webhooks")
def webhooks():
    return []


@app.post("/api/v1/webhooks/{webhook_id}/trigger")
def trigger_webhook(webhook_id: str):
    return {"ok": True}


@app.get("/healthz")
def healthz():
    return {"ok": True, "hermes": str(HERMES), "db": STATE_DB.exists()}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "9130")))
