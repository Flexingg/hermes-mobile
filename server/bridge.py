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
import yaml
from pathlib import Path

import psutil
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

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
# Firebase service-account JSON for FCM push (server-side). Optional.
FCM_SERVICE_ACCOUNT = os.environ.get(
    "FCM_SERVICE_ACCOUNT", "/home/hermes/.hermes/secrets/mercury-fcm-service-account.json"
)
DEVICE_TOKENS = HERMES / "mercury_devices.json"
UPLOADS_DIR = HERMES / "uploads"
UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
GROUP_STORE = HERMES / "mercury_groups.json"

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
# FCM push (server-side). Optional: no-op gracefully if Firebase isn't set up.
# ---------------------------------------------------------------------------
def _load_tokens() -> list[str]:
    try:
        data = json.loads(DEVICE_TOKENS.read_text())
        return list(dict.fromkeys(data.get("tokens", [])))
    except Exception:
        return []


def _save_tokens(tokens: list[str]) -> None:
    DEVICE_TOKENS.parent.mkdir(parents=True, exist_ok=True)
    DEVICE_TOKENS.write_text(json.dumps({"tokens": list(dict.fromkeys(tokens))}))


_messaging = None


def _fcm():
    """Lazily init firebase_admin messaging. Returns None if unavailable."""
    global _messaging
    if _messaging is not None:
        return _messaging
    if not os.path.exists(FCM_SERVICE_ACCOUNT):
        return None
    try:
        import firebase_admin
        from firebase_admin import credentials, messaging

        if not firebase_admin._apps:
            cred = credentials.Certificate(FCM_SERVICE_ACCOUNT)
            firebase_admin.initialize_app(cred)
        _messaging = messaging
        return _messaging
    except Exception:
        return None


def _send_push(title: str, body: str, data: dict | None = None) -> int:
    """Send a push to every registered device token. Returns # messages sent."""
    messaging = _fcm()
    if messaging is None:
        return 0
    tokens = _load_tokens()
    sent = 0
    bad = []
    for tok in tokens:
        try:
            msg = messaging.Message(
                notification=messaging.Notification(title=title, body=body),
                data={k: str(v) for k, v in (data or {}).items()},
                token=tok,
            )
            messaging.send(msg)
            sent += 1
        except Exception:
            bad.append(tok)  # e.g. invalid/expired token
    if bad:
        _save_tokens([t for t in tokens if t not in bad])
    return sent


def _send_chat_reply_push(session_id: str) -> None:
    """After a chat reply finishes, read the last assistant text and push it."""
    try:
        con = _db()
        row = con.execute(
            """SELECT content FROM messages
               WHERE session_id=? AND role='assistant' AND content IS NOT NULL
                 AND content != '' ORDER BY timestamp DESC LIMIT 1""",
            (session_id,),
        ).fetchone()
        con.close()
        text = (row["content"] if row else "").strip()
        if not text:
            return
        body = text[:200]
        _send_push("Hermes replied", body, {"type": "chat", "session_id": session_id})
    except Exception:
        pass


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
                "text": _strip_media(text),
                "timestamp": _iso(r["timestamp"]),
                "toolName": r["tool_name"],
                "media": _media_in(text) if r["role"] == "assistant" else [],
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


def _classify_line(line: str, state: dict) -> str:
    """Classify a raw Hermes CLI output line for the UI.

    Returns 'skip' (drop), 'thinking', 'technical' (status/tool noise) or
    'answer' (the agent's actual reply). `state` carries whether we're inside
    the '╭─ Hermes ─╮' thinking box across lines.
    """
    s = line.strip()
    if not s:
        return "skip"
    if s.startswith("╭"):
        state["thinking"] = True
        return "thinking"
    if s.startswith("╰"):
        state["thinking"] = False
        return "thinking"
    if state.get("thinking"):
        return "thinking"
    # Tool-progress lines are drawn with a leading ┊ bar.
    if s.startswith("┊"):
        return "technical"
    # Status markers.
    if s.startswith(("Query:", "Initializing", "↻", "⚡", "⚠", "⌛", "⏸", "✔",
                     "✖", "Completed", "Thinking", "Session:", "session_id:")) \
            or "interrupt" in s.lower():
        return "technical"
    # Pure separator / box-drawing-only lines -> drop.
    if all(c in "─━┃│═║╭╮╰╯" for c in s):
        return "skip"
    return "answer"


def _media_in(text: str | None) -> list[dict]:
    """Find `MEDIA:<path>` references an agent used to hand a file to the user."""
    out = []
    for m in re.finditer(r"MEDIA:\s*(\S+)", text or ""):
        p = Path(m.group(1)).expanduser()
        out.append({"path": str(p), "name": p.name})
    return out


def _strip_media(text: str | None) -> str:
    """Remove `MEDIA:<path>` tokens from the visible text (the file is shown
    as a download chip, not as a raw path in the bubble)."""
    return re.sub(r"MEDIA:\s*\S+", "", text or "").strip()


# ---------------------------------------------------------------------------
# Group chats (multi-agent fan-out)
# ---------------------------------------------------------------------------
def _load_groups() -> list[dict]:
    try:
        return json.loads(GROUP_STORE.read_text()).get("groups", [])
    except Exception:
        return []


def _save_groups(groups: list[dict]) -> None:
    GROUP_STORE.write_text(json.dumps({"groups": groups}, indent=2))


def _get_group(gid: str) -> dict | None:
    for g in _load_groups():
        if g["id"] == gid:
            return g
    return None


def _append_group_message(gid: str, msg: dict) -> None:
    groups = _load_groups()
    for g in groups:
        if g["id"] == gid:
            g.setdefault("messages", []).append(msg)
            g["lastActivity"] = _iso(_now())
            g["lastPreview"] = (msg.get("text") or "")[:140]
            g["messageCount"] = len(g["messages"])
            break
    _save_groups(groups)


def _profile_for(agent: str) -> str | None:
    """Map an agent display name to its Hermes profile. @hermes = default."""
    if agent == "@hermes":
        return None
    a = agent.lstrip("@").strip()
    return a or None


def _spawn_group_reply(gid: str, text: str) -> None:
    group = _get_group(gid)
    if not group:
        return
    agents = group.get("agents", [])
    if not agents:
        return
    lock = threading.Lock()
    done = {"n": 0}

    def runner(agent: str) -> None:
        _run_group_agent(gid, agent, text)
        with lock:
            done["n"] += 1
            if done["n"] >= len(agents):
                _broadcast(gid, {"event": "complete"})

    for agent in agents:
        threading.Thread(target=runner, args=(agent,), daemon=True).start()


def _run_group_agent(gid: str, agent: str, text: str) -> None:
    _broadcast(gid, {"event": "start", "agent": agent})
    cmd = [HERMES_BIN, "chat", "-q", text, "-Q"]
    profile = _profile_for(agent)
    if profile:
        cmd += ["-p", profile]
    acc = ""
    try:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        if proc.stdout is not None:
            state = {"thinking": False}
            for line in proc.stdout:
                line = line.rstrip("\n")
                if not line.strip():
                    continue
                t = _classify_line(line, state)
                if t == "skip":
                    continue
                _broadcast(gid, {"event": "chunk", "agent": agent,
                                "type": t, "delta": line + "\n"})
                if t == "answer":
                    acc += line + "\n"
        proc.wait()
    except Exception:
        pass
    _append_group_message(gid, {
        "id": f"g-{int(time.time() * 1000)}-{agent}",
        "role": "assistant",
        "agent": agent,
        "text": _strip_media(acc),
        "timestamp": _iso(_now()),
        "media": _media_in(acc),
    })
    _broadcast(gid, {"event": "done", "agent": agent})


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
    attachments = body.get("attachments") or []
    _spawn_hermes(session_id, text, attachments)
    return {"ok": True, "pending": True}


def _spawn_hermes(session_id: str, text: str, attachments: list | None = None) -> None:
    attachments = attachments or []
    query = text
    img_path = None
    file_refs = []
    for a in attachments:
        p = (a.get("path") or "").strip()
        if not p or not Path(p).exists():
            continue
        kind = (a.get("kind") or "file").lower()
        name = (a.get("name") or Path(p).name)
        if kind == "image" and img_path is None:
            img_path = p
        else:
            file_refs.append(name)
    # Tell the agent about non-image files so it can read them via tools.
    if file_refs:
        refs = ", ".join(file_refs)
        query = (
            f"{query}\n\n[Attached files: {refs}. Read them with read_file/search_files if needed.]"
        )

    def run():
        cmd = [HERMES_BIN, "chat", "-q", query, "--resume", session_id]
        if img_path:
            cmd += ["--image", img_path]
        # start_new_session: run hermes in its own process group/session so
        # stray SIGHUP/SIGTERM sent to the bridge's group can't interrupt the
        # in-flight model call. stdin=/dev/null: no inherited terminal.
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        state = {"thinking": False}
        if proc.stdout is not None:
            for line in proc.stdout:
                t = _classify_line(line, state)
                if t == "skip":
                    continue
                _broadcast(session_id,
                           {"event": "chunk", "type": t, "delta": line.rstrip("\n") + "\n"})
        proc.wait()
        _broadcast(session_id, {"event": "done"})
        _send_chat_reply_push(session_id)

    t = threading.Thread(target=run, daemon=True)
    t.start()


@app.post("/api/v1/attachments")
async def upload_attachment(file: UploadFile = File(...)):
    """Accept an image/file from the app and stage it for the agent."""
    import uuid

    data = await file.read()
    if len(data) > 50 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="file too large (max 50MB)")
    safe_name = re.sub(r"[^\w.\-]+", "_", file.filename or "file")[-100:] or "file"
    uid = uuid.uuid4().hex[:8]
    dest = UPLOADS_DIR / f"{uid}_{safe_name}"
    dest.write_bytes(data)
    kind = "image" if (file.content_type or "").startswith("image/") else "file"
    return {
        "id": uid,
        "path": str(dest),
        "name": safe_name,
        "size": len(data),
        "kind": kind,
    }


def _is_within(p: Path, root: Path) -> bool:
    try:
        p.relative_to(root)
        return True
    except ValueError:
        return False


def _file_roots() -> list:
    """Directories /api/v1/files may serve from. HERMES home is always allowed.

    Extra roots come from MER_FILES_ROOTS (colon-separated absolute paths). The
    default is the app repo root, so host build artifacts (e.g. an APK the agent
    just built) are downloadable directly in the Mercury app instead of getting
    a 403 "path outside home".
    """
    roots = [HERMES.resolve()]
    extra = os.environ.get("MER_FILES_ROOTS", "").strip()
    if extra:
        items = [Path(x).expanduser().resolve() for x in extra.split(":") if x.strip()]
    else:
        items = [Path(__file__).resolve().parents[1]]
    return roots + [r for r in items if r not in roots]


@app.get("/api/v1/files")
def get_file(path: str = ""):
    """Download a file the agent produced / the app uploaded (within an allowed root)."""
    if not path:
        raise HTTPException(status_code=400, detail="path required")
    p = Path(path).expanduser().resolve()
    if not any(_is_within(p, root) for root in _file_roots()):
        raise HTTPException(status_code=403, detail="path outside allowed roots")
    if not p.is_file():
        raise HTTPException(status_code=404, detail="not found")
    name = p.name
    return Response(
        content=p.read_bytes(),
        media_type="application/octet-stream",
        headers={"Content-Disposition": f'attachment; filename="{name}"'},
    )


@app.get("/api/v1/groups")
def groups():
    return [
        {
            "id": g["id"],
            "name": g.get("name", "Group"),
            "agents": g.get("agents", []),
            "lastPreview": g.get("lastPreview", ""),
            "lastTimestamp": g.get("lastActivity"),
            "messageCount": g.get("messageCount", len(g.get("messages", []))),
        }
        for g in _load_groups()
    ]


@app.post("/api/v1/groups")
def create_group(body: dict):
    import uuid

    name = (body.get("name") or "").strip()[:100]
    agents = [a.strip() for a in (body.get("agents") or []) if a and a.strip()][:8]
    if not agents:
        raise HTTPException(status_code=400, detail="at least one agent required")
    gid = f"grp_{int(time.time())}_{uuid.uuid4().hex[:4]}"
    group = {
        "id": gid,
        "name": name or ", ".join(agents),
        "agents": agents,
        "created": _iso(_now()),
        "lastActivity": _iso(_now()),
        "lastPreview": "Group created",
        "messageCount": 0,
        "messages": [],
    }
    all_groups = _load_groups()
    all_groups.insert(0, group)
    _save_groups(all_groups)
    return {k: v for k, v in group.items() if k != "messages"}


@app.get("/api/v1/groups/{gid}/messages")
def group_messages(gid: str):
    g = _get_group(gid)
    if not g:
        raise HTTPException(status_code=404, detail="group not found")
    return g.get("messages", [])


@app.post("/api/v1/groups/{gid}/messages")
def group_send(gid: str, body: dict):
    g = _get_group(gid)
    if not g:
        raise HTTPException(status_code=404, detail="group not found")
    text = (body.get("text") or "").strip()
    _append_group_message(gid, {
        "id": f"g-{int(time.time() * 1000)}-user",
        "role": "user",
        "agent": None,
        "text": text,
        "timestamp": _iso(_now()),
        "media": [],
    })
    _spawn_group_reply(gid, text)
    return {"ok": True}


@app.delete("/api/v1/groups/{gid}")
def delete_group(gid: str):
    groups = _load_groups()
    _save_groups([g for g in groups if g["id"] != gid])
    return {"ok": True}


@app.websocket("/ws/group/{gid}")
async def ws_group(websocket: WebSocket, gid: str):
    await websocket.accept()
    q: asyncio.Queue = asyncio.Queue()
    _register_queue(gid, q)
    try:
        while True:
            payload = await q.get()
            await websocket.send_text(json.dumps(payload))
            if payload.get("event") == "complete":
                break
    except WebSocketDisconnect:
        pass
    finally:
        _unregister_queue(gid, q)


@app.post("/api/v1/devices/register")
def register_device(body: dict):
    """Register an FCM device token so the bridge can push to it."""
    tok = (body.get("token") or "").strip()
    platform = (body.get("platform") or "android")[:20]
    if not tok:
        raise HTTPException(status_code=400, detail="token required")
    tokens = _load_tokens()
    if tok not in tokens:
        tokens.append(tok)
        _save_tokens(tokens)
    return {"ok": True, "registered": tok, "platform": platform}


@app.post("/api/v1/devices/test")
def test_push(body: dict | None = None):
    """Send a test push to all registered devices. Returns count sent."""
    body = body or {}
    title = body.get("title") or "Mercury Messenger"
    message = body.get("message") or "Push works ✅"
    n = _send_push(title, message, {"type": "test"})
    return {"ok": True, "sent": n}


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


# ---- Bot (Hermes profile) CRUD ----------------------------------------
def _bot_cfg_path(profile: str) -> Path:
    if profile in ("hermes", "default"):
        return CONFIG_YAML
    return PROFILES_DIR / profile / "config.yaml"

def _bot_soul_path(profile: str) -> Path:
    if profile in ("hermes", "default"):
        return HERMES / "SOUL.md"
    return PROFILES_DIR / profile / "SOUL.md"

def _bot_load_cfg(profile: str) -> dict:
    try:
        return yaml.safe_load(_bot_cfg_path(profile).read_text()) or {}
    except Exception:
        return {}

def _bot_save_cfg(profile: str, cfg: dict) -> None:
    _bot_cfg_path(profile).write_text(
        yaml.safe_dump(cfg, sort_keys=False, default_flow_style=False))

def _bot_pet(profile: str) -> str | None:
    return (_bot_load_cfg(profile).get("display", {}) or {}).get("pet", {}).get("slug")

def _bot_model(profile: str) -> tuple:
    m = _bot_load_cfg(profile).get("model", {}) or {}
    return m.get("model"), m.get("provider")

def _bot_desc(profile: str) -> str:
    return (_bot_load_cfg(profile).get("description", "") or "").strip()

def _bot_soul(profile: str) -> str:
    p = _bot_soul_path(profile)
    try:
        return p.read_text() if p.exists() else ""
    except Exception:
        return ""

def _available_pet_slugs() -> list[str]:
    d = HERMES / "pets" / ".thumbs"
    if d.exists():
        return sorted(p.stem for p in d.glob("*.png"))
    return []

def _all_profiles() -> list[str]:
    out = ["hermes"]
    if PROFILES_DIR.exists():
        out += sorted(p.name for p in PROFILES_DIR.iterdir() if p.is_dir())
    return out

def _profile_from_bot_id(bot_id: str) -> str:
    return bot_id.removeprefix("bot-")

def _bot_to_dict(profile: str) -> dict | None:
    if profile != "hermes" and not (PROFILES_DIR / profile).is_dir():
        return None
    model, provider = _bot_model(profile)
    return {
        "id": f"bot-{profile}",
        "name": f"@{profile}" if profile != "hermes" else "@hermes",
        "description": _bot_desc(profile) or (
            "Default Hermes agent" if profile == "hermes"
            else f"Hermes profile: {profile}"),
        "model": model,
        "provider": provider,
        "pet": _bot_pet(profile),
        "soul": _bot_soul(profile),
        "isDefault": profile == "hermes",
    }

@app.get("/api/v1/bots/pets")
def bot_pets():
    return _available_pet_slugs()

@app.get("/api/v1/bots")
def bots():
    return [d for p in _all_profiles() if (d := _bot_to_dict(p))]

@app.get("/api/v1/bots/{bot_id}")
def bot_detail(bot_id: str):
    d = _bot_to_dict(_profile_from_bot_id(bot_id))
    if not d:
        raise HTTPException(status_code=404, detail="bot not found")
    return d

@app.post("/api/v1/bots")
def create_bot(body: dict):
    name = (body.get("name") or "").strip().lower().replace(" ", "-")
    if not name or not re.match(r"^[a-z0-9-]+$", name):
        raise HTTPException(status_code=400,
                            detail="invalid name (lowercase letters, numbers, dashes)")
    if (PROFILES_DIR / name).is_dir():
        raise HTTPException(status_code=409, detail="bot already exists")
    desc = (body.get("description") or "").strip()
    cmd = [HERMES_BIN, "profile", "create", name, "--no-alias"]
    if desc:
        cmd += ["--description", desc]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        raise HTTPException(status_code=500,
                            detail=proc.stderr.strip() or "create failed")
    return _bot_to_dict(name)

@app.patch("/api/v1/bots/{bot_id}")
def update_bot(bot_id: str, body: dict):
    profile = _profile_from_bot_id(bot_id)
    if profile != "hermes" and not (PROFILES_DIR / profile).is_dir():
        raise HTTPException(status_code=404, detail="bot not found")
    cfg = _bot_load_cfg(profile)
    changed = False
    if body.get("description") is not None:
        cfg["description"] = (body["description"] or "").strip()
        changed = True
    if body.get("pet") is not None:
        slug = (body["pet"] or "").strip()
        if slug and slug not in _available_pet_slugs():
            raise HTTPException(status_code=400, detail=f"unknown pet: {slug}")
        cfg.setdefault("display", {})["pet"] = {"enabled": bool(slug), "slug": slug}
        changed = True
    if changed:
        _bot_save_cfg(profile, cfg)
    if body.get("soul") is not None:
        sp = _bot_soul_path(profile)
        sp.parent.mkdir(parents=True, exist_ok=True)
        sp.write_text(body["soul"] or "")
    return _bot_to_dict(profile)

@app.delete("/api/v1/bots/{bot_id}")
def delete_bot(bot_id: str):
    profile = _profile_from_bot_id(bot_id)
    if profile == "hermes":
        raise HTTPException(status_code=400,
                            detail="cannot delete the default agent")
    if not (PROFILES_DIR / profile).is_dir():
        raise HTTPException(status_code=404, detail="bot not found")
    proc = subprocess.run([HERMES_BIN, "profile", "delete", profile, "-y"],
                          capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        raise HTTPException(status_code=500,
                            detail=proc.stderr.strip() or "delete failed")
    return {"ok": True}


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


# ---------------------------------------------------------------------------
# Remote terminal: run commands on the host PC from the app.
# Gated by the bearer-token middleware above. Optional kill-switch via the
# ENABLE_TERMINAL env var (default "1"). Commands run as the hermes user.
# ---------------------------------------------------------------------------
TERMINAL_DIR = Path(os.environ.get("TERMINAL_CWD", str(HERMES)))
ENABLE_TERMINAL = os.environ.get("ENABLE_TERMINAL", "1") == "1"


@app.post("/api/v1/terminal/run")
def terminal_run(body: dict):
    """Run a shell command on the host and return its output."""
    if not ENABLE_TERMINAL:
        raise HTTPException(status_code=403, detail="remote terminal disabled")
    command = (body.get("command") or "").strip()
    if not command:
        raise HTTPException(status_code=400, detail="command required")
    if len(command) > 8000:
        raise HTTPException(status_code=400, detail="command too long")
    cwd_raw = (body.get("cwd") or "").strip()
    timeout = max(1, min(int(body.get("timeout") or 300), 1800))
    if not cwd_raw:
        cwd_path = TERMINAL_DIR.resolve()
    else:
        try:
            cwd_path = Path(cwd_raw).expanduser().resolve()
            if not cwd_path.is_dir():
                cwd_path = TERMINAL_DIR.resolve()
        except Exception:
            cwd_path = TERMINAL_DIR.resolve()
    start = time.time()
    try:
        p = subprocess.run(
            command, shell=True, cwd=str(cwd_path), capture_output=True,
            text=True, timeout=timeout,
        )
        return {
            "command": command,
            "cwd": str(cwd_path),
            "stdout": p.stdout or "",
            "stderr": p.stderr or "",
            "exitCode": p.returncode,
            "durationMs": int((time.time() - start) * 1000),
            "timedOut": False,
        }
    except subprocess.TimeoutExpired:
        return {
            "command": command,
            "cwd": str(cwd_path),
            "stdout": "",
            "stderr": f"Command timed out after {timeout}s",
            "exitCode": -1,
            "durationMs": timeout * 1000,
            "timedOut": True,
        }
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"failed: {e}")


@app.get("/healthz")
def healthz():
    return {"ok": True, "hermes": str(HERMES), "db": STATE_DB.exists()}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "9130")))
