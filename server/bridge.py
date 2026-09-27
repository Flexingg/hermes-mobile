#!/usr/bin/env python3
"""Hermes Mobile bridge — fronts a REAL Hermes install for the Flutter app.

Serves the REST + WebSocket contract the app's `HermesRepository` expects,
reading live data straight from `~/.hermes`:
  - sessions & messages   -> state.db (SQLite)
  - model / provider      -> config.yaml
  - memory                -> memories/USER.md + memories/MEMORY.md
  - cron jobs             -> cron/jobs.json (writes go through the hermes CLI)
  - skills                -> skills/**/SKILL.md
  - logs                  -> logs/*.log
  - chat (streaming)      -> real `hermes chat --resume <id>` subprocess

Security: BRIDGE_TOKEN is REQUIRED (the process exits without it) and guards
every route — `/api/v1/*`, `/html/*` and both WebSockets. Listen address comes
from BRIDGE_HOST (default 0.0.0.0; set it to a loopback/Tailscale address).

Run:  BRIDGE_TOKEN=... uvicorn bridge:app --host 127.0.0.1 --port 9130
"""
from __future__ import annotations

import asyncio
import datetime as dt
import hmac
import json
import os
import re
import signal
import sqlite3
import subprocess
import threading
import time
import urllib.error
import urllib.request
import yaml
import zoneinfo
from contextlib import asynccontextmanager
from pathlib import Path

import psutil
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from starlette.requests import Request
from starlette.responses import FileResponse, JSONResponse, Response

try:  # run as `python server/bridge.py` (the systemd unit) or with server/ on sys.path (tests)
    from hermes_api import HermesApi, HermesApiError, STOP_STEER_NOTE, named_profile
except ImportError:  # `uvicorn server.bridge:app` from the repo root
    from server.hermes_api import HermesApi, HermesApiError, STOP_STEER_NOTE, named_profile

HERMES = Path(os.environ.get("HERMES_HOME", str(Path.home() / ".hermes")))
STATE_DB = HERMES / "state.db"
CONFIG_YAML = HERMES / "config.yaml"
MEM_DIR = HERMES / "memories"
CRON_JOBS = HERMES / "cron" / "jobs.json"
LOGS_DIR = HERMES / "logs"
SKILLS_DIR = HERMES / "skills"
PROFILES_DIR = HERMES / "profiles"

# Bearer token. REQUIRED — fail closed.
#
# The bridge fronts this machine's ~/.hermes (chat history in state.db, config,
# the whole preview/file root) and can run shell commands as `hermes`. Started
# without a token it is a full compromise of the machine for anything on the
# LAN, so we refuse to boot instead of quietly serving everything. Previously
# the token was optional AND only guarded /api/v1, which left `/html/<path>`
# serving `~/.hermes/config.yaml`, `.env` and the 144 MB `state.db` to any
# host on the network with no credential at all.
BRIDGE_TOKEN = (os.environ.get("BRIDGE_TOKEN") or "").strip()
# Values from the shipped unit template / copy-paste. Accepting one of these is
# the same as having no token: the placeholder is public.
_PLACEHOLDER_TOKENS = {
    "replace_with_token", "change_me", "changeme", "token", "secret",
    "yoursecret", "your-secret", "password", "test",
}
if not BRIDGE_TOKEN:
    raise SystemExit(
        "BRIDGE_TOKEN is required — refusing to start an unauthenticated bridge.\n"
        "The bridge serves ~/.hermes (chat history, config, model keys) and can "
        "run shell commands as the hermes user. Set BRIDGE_TOKEN (see "
        "server/hermes-bridge.service and README > Security)."
    )
if BRIDGE_TOKEN.lower() in _PLACEHOLDER_TOKENS or len(BRIDGE_TOKEN) < 16:
    raise SystemExit(
        "BRIDGE_TOKEN is a placeholder or too short (min 16 chars) — refusing to "
        "start. Generate one with `openssl rand -hex 24` and put it in the unit's "
        "EnvironmentFile."
    )

# Where to listen. The default stays 0.0.0.0 because the deployed unit sets no
# BRIDGE_HOST and the phone reaches the bridge over the LAN — silently changing
# the default here would take the app offline on the next service restart. To
# close the port, set BRIDGE_HOST to a loopback/Tailscale address in the unit
# (a deployment change, not a code change). Non-loopback binds log a warning.
BRIDGE_HOST = (os.environ.get("BRIDGE_HOST") or "0.0.0.0").strip() or "0.0.0.0"

# Browser origins allowed to call the API. Empty (the default) emits no CORS
# headers at all: the Android client is not a browser and never needed the old
# `allow_origins=["*"]`, which let any web page a browser opened talk to the
# bridge. Set MER_CORS_ORIGINS=https://foo,https://bar if a web build needs it.
CORS_ORIGINS = [
    o.strip() for o in os.environ.get("MER_CORS_ORIGINS", "").split(",") if o.strip()
]
# Absolute path to the `hermes` CLI (systemd services don't inherit ~/.local/bin).
HERMES_BIN = os.environ.get("HERMES_BIN", "/home/hermes/.local/bin/hermes")
# The resident gateway's API server. Chat turns for the profiles it serves go
# through it; everything else (and any turn it can't take) uses HERMES_BIN.
HERMES_API = HermesApi(
    HERMES, multiplex=lambda: bool((_config().get("gateway") or {}).get("multiplex_profiles")))
# Firebase service-account JSON for FCM push (server-side). Optional.
FCM_SERVICE_ACCOUNT = os.environ.get(
    "FCM_SERVICE_ACCOUNT", "/home/hermes/.hermes/secrets/mercury-fcm-service-account.json"
)
DEVICE_TOKENS = HERMES / "mercury_devices.json"
UPLOADS_DIR = HERMES / "uploads"
UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
GROUP_STORE = HERMES / "mercury_groups.json"
# Allowed vault root for Tasker scan_vault tasks. No default (must be configured).
MER_VAULT_PATH = os.environ.get("MER_VAULT_PATH", "")
# Default agent profile for chat ("" = default profile).
MER_CHAT_PROFILE = os.environ.get("MER_CHAT_PROFILE", "")
# SparkyFitness coach budget integration (R10-1). Never log or return SPARKY_TOKEN.
SPARKY_BASE_URL = os.environ.get("SPARKY_BASE_URL", "https://fit.randalls.cc")
SPARKY_TOKEN = os.environ.get("SPARKY_TOKEN", "")
MER_COACH_PUSH_TIMES = os.environ.get("MER_COACH_PUSH_TIMES", "")
MER_COACH_TZ = os.environ.get("MER_COACH_TZ", "")


def _chat_profile() -> str | None:
    val = os.environ.get("MER_CHAT_PROFILE", MER_CHAT_PROFILE).strip()
    return val or None


@asynccontextmanager
async def lifespan(app: FastAPI):
    times_str = (os.environ.get("MER_COACH_PUSH_TIMES") or MER_COACH_PUSH_TIMES or "").strip()
    task = None
    if times_str:
        task = asyncio.create_task(_coach_scheduler_loop(times_str))
    yield
    if task:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass


app = FastAPI(
    title="Hermes Mobile bridge",
    version="1.0",
    lifespan=lifespan,
    # FastAPI serves /docs, /redoc and /openapi.json by default and they are
    # NOT under /api/v1, so the auth middleware never saw them: any host on the
    # LAN could read the full route map (including /api/v1/terminal/run) without
    # a token. Off unless explicitly opted in.
    docs_url="/docs" if os.environ.get("MER_ENABLE_DOCS") == "1" else None,
    redoc_url="/redoc" if os.environ.get("MER_ENABLE_DOCS") == "1" else None,
    openapi_url="/openapi.json" if os.environ.get("MER_ENABLE_DOCS") == "1" else None,
)
app.add_middleware(
    CORSMiddleware, allow_origins=CORS_ORIGINS, allow_methods=["*"], allow_headers=["*"]
)


def _token_ok(supplied: str | None) -> bool:
    """Constant-time bearer comparison (a plain `==` leaks the token by timing).

    Compared as UTF-8 bytes: `hmac.compare_digest` raises TypeError on a str
    containing non-ASCII characters, which turned a hostile `Authorization`
    header into a 500 instead of a 401.
    """
    if not supplied:
        return False
    try:
        return hmac.compare_digest(str(supplied).encode("utf-8"), BRIDGE_TOKEN.encode("utf-8"))
    except Exception:  # noqa: BLE001 - never 500 on a malformed credential
        return False


def _request_token(request) -> str:
    """Bearer token from the `Authorization` header, else from `?token=`.

    The query form exists because a WebView (HTML preview) and the Dart
    `WebSocketChannel` cannot always attach a header; it is the same secret
    either way. Never log the return value.
    """
    auth = request.headers.get("authorization", "") or ""
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    try:
        return (request.query_params.get("token") or "").strip()
    except Exception:  # noqa: BLE001 - no query_params on the object
        return ""


@app.middleware("http")
async def auth_middleware(request: Request, call_next):
    if request.url.path.startswith("/api/v1") and not _token_ok(_request_token(request)):
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
def _profile_db_path(profile: str | None) -> Path:
    """Hermes keeps one state.db per profile: a chat run as `lumen` is stored in
    profiles/lumen/state.db, never in the default one."""
    name = named_profile(profile)
    return STATE_DB if name is None else PROFILES_DIR / name / "state.db"


def _db(profile: str | None = None) -> sqlite3.Connection:
    con = sqlite3.connect(_profile_db_path(profile))
    con.row_factory = sqlite3.Row
    return con


def _listed_profiles() -> list[str | None]:
    """Profiles whose chats the app lists: the default one, plus the chat profile
    (MER_CHAT_PROFILE) that new chats from the app run as."""
    out: list[str | None] = [None]
    try:
        chat = named_profile(_chat_profile())
    except ValueError:
        chat = None
    if chat and _profile_db_path(chat).exists():
        out.append(chat)
    return out


def _owner_candidates() -> list[str | None]:
    """Profiles a chat can belong to: the listed ones, plus every linked project's
    agent (a project chat lives in that agent's own state.db)."""
    out = _listed_profiles()
    try:
        registry = json.loads((HERMES / "mercury" / "projects.json").read_text()).get("projects", [])
    except (OSError, ValueError):
        registry = []
    for p in registry:
        try:
            name = named_profile(p.get("profile"))
        except ValueError:
            continue
        if name and name not in out:
            out.append(name)
    return out


def _session_owner(session_id: str) -> str:
    """The profile whose state.db holds this session ("default" if none does)."""
    for prof in reversed(_owner_candidates()):
        path = _profile_db_path(prof)
        if not path.exists():
            continue
        try:
            con = _db(prof)
            try:
                hit = con.execute("SELECT 1 FROM sessions WHERE id=?", (session_id,)).fetchone()
            finally:
                con.close()
        except sqlite3.Error:
            continue
        if hit:
            return prof or "default"
    return "default"


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
        con = _db(_session_owner(session_id))
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
        # True when chat turns go through the resident gateway's API server
        # rather than a `hermes chat` process per message.
        "hermesApi": HERMES_API.available(),
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
    return _list_sessions(_listed_profiles())


def _list_sessions(profiles: list[str | None]) -> list[dict]:
    out = []
    for prof in profiles:
        if prof is not None and not _profile_db_path(prof).exists():
            continue
        con = _db(prof)
        try:
            rows = con.execute(
                """SELECT id, title, display_name, last_activity_at, started_at,
                          last_activity_description, message_count, pinned, source
                   FROM sessions WHERE archived=0 AND hidden=0
                   ORDER BY last_activity_at DESC LIMIT 200"""
            ).fetchall()
        except sqlite3.Error:
            # A profile whose db exists but is empty or older than the schema
            # (a fresh profile directory, say) must not break the whole list.
            continue
        finally:
            con.close()
        for r in rows:
            title = r["title"] or r["display_name"] or r["source"] or "Conversation"
            ts = r["last_activity_at"] or r["started_at"] or _now()
            if prof is not None:
                # a profile's own db: the profile is who you are talking to
                profile_id = prof
            else:
                # Sessions started through the API server are the default
                # profile's; show them under the same bot as CLI-started ones.
                profile_id = ("hermes" if r["source"] == "api_server" else r["source"]) or "hermes"
            out.append(
                {
                    "id": r["id"],
                    "title": title,
                    "lastPreview": (r["last_activity_description"] or "")[:140],
                    "lastTimestamp": _iso(ts),
                    "unreadCount": 0,
                    "pinned": bool(r["pinned"]),
                    "starred": False,
                    "profileId": profile_id,
                    "color": _hash_color(r["id"]),
                    "_ts": ts,
                }
            )
    out.sort(key=lambda x: x.pop("_ts"), reverse=True)
    return out[:200]


@app.get("/api/v1/sessions/{session_id}/messages")
def messages(session_id: str):
    con = _db(_session_owner(session_id))
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


# ---------------------------------------------------------------------------
# Hermes' CLI chrome is not the agent talking.
#
# `hermes chat` prints a session banner around the reply: "Session <id> found but
# has no messages. Starting fresh.", a "Resume this session with:" hint, and a
# "Title:/Duration:/Messages:" summary. Streamed straight through, those lines
# landed in the transcript as if the assistant had said them — they match none of
# the status prefixes below, so they were classified 'answer'. They are plumbing:
# they never reach a bubble. The facts they carry become a `session_meta` event,
# which the app renders as a collapsed row under the reply.
# ---------------------------------------------------------------------------
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")

_PLUMBING_PREFIXES = (
    "Query:", "Initializing agent", "Session:", "session_id:", "Title:", "Duration:",
    "Messages:", "Tools:", "Model:", "Profile:", "Tokens:", "Resume with:",
    "Resume this session with:", "Connected to", "🔗",
)
_PLUMBING_RE = (
    re.compile(r"^Session\s+\S+\s+found but has no messages"),
    re.compile(r"^attaching\s+\d+\s+image\(s\)"),
    re.compile(r"^hermes\s+(--resume|-c)\b"),  # the two hint commands under the banner
    re.compile(r"^\d+\s*\(\d+\s+user.*tool call"),  # "2 (1 user, 0 tool calls)" summary tail
    re.compile(r"^\S+\s+·\s+\d+s$"),  # "Assistant · 19s" style run footer
    # The bare filename an "attaching N image(s)" banner wraps onto. A line that is
    # only a filename is a file reference (the app shows those as chips), never the
    # agent's prose.
    re.compile(r"^[\w.\-]+\.(png|jpe?g|gif|webp|bmp|heic|pdf|txt|md|csv|json|apk|zip)$",
               re.IGNORECASE),
)
# Banner label (lowercased) -> the key the app shows. Order of appearance wins.
_META_KEYS = {
    "session": "sessionId", "session_id": "sessionId", "title": "title",
    "duration": "duration", "messages": "messages", "model": "model", "profile": "profile",
}

# Emitted once per turn instead of the banner text.
_SESSION_META_EVENT = "session_meta"


# The response panel: `╭─ ⚕ Hermes ──…──╮` … `╰─…─╯`. Its contents *are* the answer
# (the label is the skin's `response_label`). Older bridge code treated every box
# as a thinking box, so a `hermes chat` turn showed the reply as collapsed
# "thinking" and the session banner as the answer — exactly backwards.
_RESPONSE_BOX_RE = re.compile(r"^╭[─\s][^╮]*Hermes")
# How much longer than the prompt the echoed "Query:" block may get before we
# decide it was not an echo at all. The prompt wraps across lines; the echo is a
# prefix of what we sent, so it can never be much longer.
_ECHO_SLACK = 40


def is_cli_plumbing(line: str) -> bool:
    """True for a line of Hermes CLI chrome — never shown as the agent's words."""
    s = _ANSI_RE.sub("", line or "").strip()
    if not s:
        return False
    return s.startswith(_PLUMBING_PREFIXES) or any(r.match(s) for r in _PLUMBING_RE)


def parse_cli_plumbing(lines: list[str]) -> dict:
    """The session facts a turn's banner carried ({} when there was no banner)."""
    meta: dict[str, str] = {}
    for raw in lines:
        s = _ANSI_RE.sub("", raw or "").strip()
        m = re.match(r"^Session\s+(\S+)\s+found but has no messages", s)
        if m:
            meta.setdefault("sessionId", m.group(1))
            meta.setdefault("note", "no messages in this session yet — started fresh")
            continue
        m = re.match(r"^hermes\s+--resume\s+(\S+)", s)
        if m:
            meta["resumeCommand"] = f"hermes --resume {m.group(1)}"
            meta.setdefault("sessionId", m.group(1))
            continue
        m = re.match(r"^([A-Za-z_]+):\s*(.+)$", s)
        if m:
            key = _META_KEYS.get(m.group(1).strip().lower())
            if key:
                meta.setdefault(key, m.group(2).strip())
    sid = meta.get("sessionId")
    if sid:
        meta.setdefault("resumeCommand", f"hermes --resume {sid}")
    return meta


def strip_cli_plumbing(text: str) -> str:
    """`text` with Hermes' CLI chrome removed (bubbles and tasker answers)."""
    kept = [ln for ln in _ANSI_RE.sub("", text or "").splitlines() if not is_cli_plumbing(ln)]
    return "\n".join(kept).strip()


def _classify_line(line: str, state: dict) -> str:
    """Classify a raw Hermes CLI output line for the UI.

    Returns 'skip' (drop), 'meta' (CLI plumbing — collected, never shown),
    'thinking', 'technical' (status/tool noise) or 'answer' (the agent's actual
    reply).

    `state` carries, across lines: the box we are inside (`answer` for the
    response panel, `chrome` for any other panel), whether a tool/status box is
    open (the older `thinking` flag) and how much of the echoed prompt we have
    dropped. Set `state["sent"]` to the text we handed the CLI so the echo of it
    can be recognised.
    """
    s = line.strip()
    if not s:
        return "skip"
    # `hermes chat -q` echoes the prompt as "Query: …", wrapping it over as many
    # lines as it needs, and only stops at "Initializing agent...". The app
    # already shows that text as the user's own message; left in, the wrapped tail
    # is classified 'answer' and the assistant appears to repeat the user.
    echo = state.get("echo")
    if echo is not None:
        if s.startswith("Initializing"):
            state["echo"] = None
            return "meta"
        state["echo"] = echo + s
        if len(state["echo"]) <= len(state.get("sent") or "") + _ECHO_SLACK:
            return "meta"
        # Longer than anything we sent: not an echo after all. Fall through and
        # classify this line on its own merits.
        state["echo"] = None
    if s.startswith("Query:"):
        state["echo"] = s[len("Query:"):].strip()
        return "meta"
    # Box borders. The response panel holds the answer; any other box is chrome.
    if s.startswith("╭"):
        state["box"] = "answer" if _RESPONSE_BOX_RE.match(s) else "chrome"
        # Another kind of box (stash, clarify, …) keeps the old behaviour: its
        # contents are collapsible, not the answer.
        state["thinking"] = state["box"] == "chrome"
        return "skip" if state["box"] == "answer" else "thinking"
    if s.startswith("╰"):
        answer_box = state.pop("box", None) == "answer"
        state["thinking"] = False
        return "skip" if answer_box else "thinking"
    if state.get("box") == "answer":
        return "answer"
    if state.get("thinking"):
        return "thinking"
    # Hermes' own session banner / run summary: collected for the meta row, never
    # shown as the agent's words.
    if is_cli_plumbing(s):
        return "meta"
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


_PREVIEW_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".htm": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".mjs": "application/javascript; charset=utf-8",
    ".json": "application/json",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".webp": "image/webp",
    ".ico": "image/x-icon",
    ".txt": "text/plain; charset=utf-8",
    ".md": "text/plain; charset=utf-8",
}


def _media_in(text: str | None) -> list[dict]:
    """Find `MEDIA:<path>` references an agent used to hand a file to the user."""
    out = []
    for m in re.finditer(r"MEDIA:\s*(\S+)", text or ""):
        p = Path(m.group(1)).expanduser()
        kind = "html" if p.suffix.lower() in (".html", ".htm") else "file"
        out.append({"path": str(p), "name": p.name, "kind": kind})
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
            state = {"thinking": False, "sent": text}
            for line in proc.stdout:
                line = line.rstrip("\n")
                if not line.strip():
                    continue
                t = _classify_line(line, state)
                if t in ("skip", "meta"):
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
    base_title = (body.get("title") or "New conversation")[:200]
    title = base_title
    profile = (body.get("profile") or body.get("profileId") or _chat_profile() or "hermes").strip()
    try:
        db_profile = profile if _profile_db_path(profile).exists() else None
    except ValueError:
        raise HTTPException(status_code=400, detail="invalid profile")
    con = _db(db_profile)
    try:
        con.execute(
            """INSERT INTO sessions (id, source, title, started_at, last_activity_at,
                                     message_count, tool_call_count, archived, hidden)
               VALUES (?,?,?,?,?,0,0,0,0)""",
            (sid, profile, title, _now(), _now()),
        )
    except sqlite3.IntegrityError:
        title = f"{base_title} ({sid[-6:]})"[:200]
        con.execute(
            """INSERT INTO sessions (id, source, title, started_at, last_activity_at,
                                     message_count, tool_call_count, archived, hidden)
               VALUES (?,?,?,?,?,0,0,0,0)""",
            (sid, profile, title, _now(), _now()),
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
        "profileId": profile,
        "color": _hash_color(sid),
    }


def _session_title(session_id: str, profile: str | None = None) -> str | None:
    """The title Hermes gave a session (auto-titling may not have run yet)."""
    try:
        con = _db(profile)
        try:
            row = con.execute("SELECT title FROM sessions WHERE id=?", (session_id,)).fetchone()
        finally:
            con.close()
    except sqlite3.Error:
        return None
    return (row["title"] or None) if row else None


@app.post("/api/v1/chat/start")
def chat_start(body: dict):
    """Start a REAL new Hermes conversation: runs `hermes chat -q <text>` (which
    creates a genuine session), parses the returned session id, and returns it."""
    text = (body.get("text") or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="text required")
    profile = (body.get("profile") or body.get("profileId") or _chat_profile() or "").strip() or None
    if HERMES_API.serves(profile) and HERMES_API.available():
        try:
            sid = HERMES_API.create_session(title=body.get("name") or None, profile=profile)
        except HermesApiError as e:
            print(f"[bridge] API server could not create a session ({e}); using the CLI", flush=True)
        else:
            # The session exists now, so a failure from here on is reported
            # rather than retried through the CLI (that would start a second chat).
            try:
                # same limit the CLI path has always had for a first turn
                result = HERMES_API.chat(sid, text, timeout=180, profile=profile)
            except HermesApiError as e:
                raise HTTPException(status_code=502, detail=f"hermes failed: {e}")
            title = (_session_title(result["session_id"], profile) or body.get("name") or text)[:200]
            return {
                "id": result["session_id"],
                "title": title,
                "lastPreview": text[:140],
                "lastTimestamp": _iso(_now()),
                "unreadCount": 0,
                "pinned": False,
                "starred": False,
                "profileId": profile or "hermes",
                "color": _hash_color(result["session_id"]),
            }
    cmd = [HERMES_BIN, "chat", "-q", text, "--pass-session-id"]
    if profile:
        cmd += ["-p", profile]
    try:
        p = subprocess.run(
            cmd,
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
        "profileId": profile or "hermes",
        "color": _hash_color(sid),
    }


@app.post("/api/v1/sessions/{session_id}/messages")
def send_message(session_id: str, body: dict):
    text = (body.get("text") or "").strip()
    attachments = body.get("attachments") or []
    # The profile that owns the session runs the turn: resuming it as any other
    # profile would look in the wrong state.db and lose the history.
    profile = body.get("profile") or body.get("profileId") or _session_owner(session_id)
    try:
        named_profile(profile)
    except ValueError:
        raise HTTPException(status_code=400, detail="invalid profile")
    system = None
    if (body.get("mode") or "chat") == "plan":
        project = _project_for(body.get("project"), profile)
        text = f"[Mercury Plan · project {project['id']} · {project['repo']}]\n{text}"
        system = _PLAN_SYSTEM.format(**project)
    _spawn_hermes(session_id, text, attachments, profile=profile, system=system)
    return {"ok": True, "pending": True}


# ---- Live turn control (Stop) --------------------------------------------------
# One entry per turn this bridge is running, keyed by session id. Stop needs
# something to act on, and neither transport is keyed the way the app is: the
# gateway's steer/stop routes take the RUN id it assigns to a turn (it has no
# session-keyed stop at all), and the CLI fallback has a process instead. Both
# are recorded here for the duration of the turn.
ACTIVE_RUNS: dict[str, dict] = {}
_ACTIVE_LOCK = threading.Lock()


def _register_run(session_id: str, profile: str | None, kind: str = "api") -> None:
    with _ACTIVE_LOCK:
        ACTIVE_RUNS[session_id] = {"run_id": None, "profile": profile, "proc": None,
                                   "kind": kind, "started": time.time(),
                                   "stop_requested": None}


def _set_run_id(session_id: str, run_id: str) -> None:
    """The gateway told us which run this turn is (first SSE event)."""
    with _ACTIVE_LOCK:
        info = ACTIVE_RUNS.get(session_id)
        if info is not None:
            info["run_id"] = run_id


def _set_run_proc(session_id: str, proc) -> None:
    """The CLI fallback's process, so Stop can signal it."""
    with _ACTIVE_LOCK:
        info = ACTIVE_RUNS.get(session_id)
        if info is not None:
            info["proc"] = proc


def _clear_run(session_id: str) -> None:
    with _ACTIVE_LOCK:
        ACTIVE_RUNS.pop(session_id, None)


def _active_run(session_id: str) -> dict | None:
    with _ACTIVE_LOCK:
        info = ACTIVE_RUNS.get(session_id)
        return dict(info) if info else None


def _request_stop(session_id: str, *, hard: bool) -> str:
    """Stop the turn running on this session; returns what was actually done.

    ``"graceful"`` — a steer: the agent finishes the step it is on, then ends the
    turn. Nothing is torn down, so the reply stays a coherent answer.
    ``"hard"`` — interrupt the run where it is, reaping what it started.
    ``"none"`` — nothing was running (the reply beat the tap).
    """
    info = _active_run(session_id)
    if info is None:
        return "none"
    profile = info.get("profile")
    run_id = info.get("run_id")
    if run_id and HERMES_API.serves(profile) and HERMES_API.available():
        try:
            done = (HERMES_API.stop_run(run_id, profile=profile) if hard
                    else HERMES_API.steer_run(run_id, STOP_STEER_NOTE, profile=profile))
        except HermesApiError as e:
            print(f"[bridge] stop request failed ({e})", flush=True)
            done = False
        if done:
            with _ACTIVE_LOCK:
                info = ACTIVE_RUNS.get(session_id)
                if info is not None:
                    info["stop_requested"] = "hard" if hard else "graceful"
            return "hard" if hard else "graceful"
    proc = info.get("proc")
    if proc is not None and proc.poll() is None:  # the CLI fallback
        # The one place the bridge signals a process, and only ever the handle it
        # started for this turn (recorded in ACTIVE_RUNS above). It never looks a
        # process up by pid or name, so it cannot reach a gateway, agent or coder
        # run Mercury does not own — the never-touch rule (PLAN §6.6). The guard
        # test in server/tests/test_projects.py keeps it that way.
        try:
            proc.send_signal(signal.SIGKILL if hard else signal.SIGINT)
        except OSError:
            return "none"
        return "hard" if hard else "graceful"
    return "none"


@app.post("/api/v1/sessions/{session_id}/stop")
def stop_turn(session_id: str, body: dict | None = None):
    """Stop the turn running on this session.

    `mode: "graceful"` (default) asks the agent to finish the step it is on and
    end the turn; `mode: "hard"` cuts the run off wherever it is. The app sends
    graceful on the first tap of Stop and hard on the confirmed second one.
    """
    mode = str((body or {}).get("mode") or "graceful").lower()
    if mode not in ("graceful", "hard"):
        raise HTTPException(status_code=400, detail="mode must be 'graceful' or 'hard'")
    applied = _request_stop(session_id, hard=(mode == "hard"))
    _broadcast(session_id, {"event": "stop_requested", "mode": mode, "applied": applied})
    return {"ok": True, "mode": mode, "applied": applied}


def _spawn_hermes(
    session_id: str, text: str, attachments: list | None = None, profile: str | None = None,
    system: str | None = None,
) -> None:
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
    prof = (profile or _chat_profile() or "").strip() or None
    _register_run(session_id, prof)

    def run():
        try:
            # Images still need the CLI's --image; everything else goes to the
            # resident gateway when it serves this profile.
            if img_path is None and HERMES_API.serves(prof) and HERMES_API.available():
                try:
                    HERMES_API.stream_chat(session_id, query, lambda c: _broadcast(session_id, c),
                                           profile=prof, system=system,
                                           on_run=lambda rid: _set_run_id(session_id, rid))
                    _broadcast(session_id, {"event": "done"})
                    _send_chat_reply_push(session_id)
                    return
                except HermesApiError as e:
                    if e.started:
                        # Part of the reply is already on screen: running the turn
                        # again through the CLI would answer twice. Say what broke.
                        _broadcast(session_id, {"event": "chunk", "type": "technical",
                                                "delta": f"⚠ {e}\n"})
                        _broadcast(session_id, {"event": "done"})
                        return
                    print(f"[bridge] API server did not take the turn ({e}); using the CLI", flush=True)
            _run_hermes_cli(session_id, query, img_path, prof)
        finally:
            _clear_run(session_id)

    t = threading.Thread(target=run, daemon=True)
    t.start()


def _run_hermes_cli(session_id: str, query: str, img_path: str | None, prof: str | None) -> None:
    """The original transport: one `hermes chat --resume` process per turn."""
    cmd = [HERMES_BIN, "chat", "-q", query, "--resume", session_id]
    if img_path:
        cmd += ["--image", img_path]
    if named_profile(prof):
        cmd += ["-p", named_profile(prof)]
    # start_new_session: run hermes in its own process group/session so
    # stray SIGHUP/SIGTERM sent to the bridge's group can't interrupt the
    # in-flight model call. stdin=/dev/null: no inherited terminal.
    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        stdin=subprocess.DEVNULL, start_new_session=True,
    )
    # Let Stop reach this turn: it has no run id here, so the process is the handle.
    _set_run_proc(session_id, proc)
    # `sent` lets the classifier recognise the echo of the prompt we just handed
    # the CLI (it wraps, and the wrapped tail is not the agent talking).
    state = {"thinking": False, "sent": query}
    plumbing: list[str] = []
    if proc.stdout is not None:
        for line in proc.stdout:
            t = _classify_line(line, state)
            if t == "meta":
                # CLI chrome: kept for the session facts it carries, never streamed.
                plumbing.append(line)
                continue
            if t == "skip":
                continue
            _broadcast(session_id,
                       {"event": "chunk", "type": t, "delta": line.rstrip("\n") + "\n"})
    proc.wait()
    meta = parse_cli_plumbing(plumbing)
    if meta:
        _broadcast(session_id, {"event": _SESSION_META_EVENT, **meta})
    _broadcast(session_id, {"event": "done"})
    _send_chat_reply_push(session_id)


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
    # Stream from disk (not read_bytes into RAM) so large files like an APK
    # transfer in chunks — far more robust over Tailscale/cellular than one
    # monolithic in-memory response, which was dropping mid-body.
    return FileResponse(p, filename=p.name, media_type="application/octet-stream")


@app.get("/html/{path:path}")
def html_preview(path: str, request: Request):
    """Serve an HTML/CSS/JS/image preview to the app's in-app WebView.

    Lives outside /api/v1 because a WebView cannot attach an Authorization
    header — so it accepts the bearer either as a header or as `?token=`
    (the app appends it; see `HermesRepository.previewUrl`), and rejects
    everything else with 401.

    Only preview-safe types are served. The previous version fell back to
    `application/octet-stream` for any unknown suffix, which turned this route
    into an unauthenticated downloader for `~/.hermes/config.yaml`, `.env` and
    the 144 MB `state.db`. Anything not in `_PREVIEW_TYPES` is now a 404.
    """
    if not _token_ok(_request_token(request)):
        raise HTTPException(status_code=401, detail="unauthorized")
    # {path:path} strips the leading '/', so rebuild an absolute filesystem path.
    p = Path("/" + path.lstrip("/")).expanduser().resolve()
    if not any(_is_within(p, root) for root in _file_roots()):
        raise HTTPException(status_code=403, detail="path outside allowed roots")
    if not p.is_file():
        raise HTTPException(status_code=404, detail="not found")
    ctype = _PREVIEW_TYPES.get(p.suffix.lower())
    if ctype is None:
        raise HTTPException(status_code=404, detail="not a previewable file type")
    return FileResponse(p, media_type=ctype)


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
    # Authenticate BEFORE accept(): the HTTP middleware does not run for the
    # WebSocket scope, so without this check any host on the LAN could subscribe
    # to group replies. A WebSocket cannot set headers from Dart's
    # WebSocketChannel, so `?token=` is accepted too.
    if not _token_ok(_request_token(websocket)):
        await websocket.close(code=1008)  # policy violation
        return
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
    # See ws_group: the HTTP middleware never runs for a WebSocket, and this
    # one streams the assistant's replies (i.e. the whole transcript).
    if not _token_ok(_request_token(websocket)):
        await websocket.close(code=1008)  # policy violation
        return
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
    con = _db(_session_owner(session_id))
    con.execute("UPDATE sessions SET last_read_at=? WHERE id=?", (_now(), session_id))
    con.commit()
    con.close()
    return {"ok": True}


@app.post("/api/v1/sessions/{session_id}/pin")
def toggle_pin(session_id: str):
    con = _db(_session_owner(session_id))
    con.execute("UPDATE sessions SET pinned = 1 - pinned WHERE id=?", (session_id,))
    con.commit()
    con.close()
    return {"ok": True}


@app.post("/api/v1/sessions/{session_id}/star")
def toggle_star(session_id: str):
    return {"ok": True}


@app.delete("/api/v1/sessions/{session_id}")
def delete_session(session_id: str):
    con = _db(_session_owner(session_id))
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


# --- cron writes ------------------------------------------------------------
# The app's Cron screen creates/edits/deletes jobs, but the bridge only exposed
# GET and `/{id}/run`, so every save was a 405 the UI swallowed. These go through
# the real `hermes cron` CLI rather than editing cron/jobs.json directly — the
# scheduler owns that file's schema (next_run, state, …) and a hand-written row
# would break it.
CRON_ID_RE = re.compile(r"\b([0-9a-f]{6,16})\b")


def _hermes_cli(args: list[str], timeout: int = 60) -> subprocess.CompletedProcess:
    """Run the `hermes` CLI and return the completed process (never raises on
    a non-zero exit — callers map that to an HTTP error with the stderr text)."""
    return subprocess.run([HERMES_BIN, *args], capture_output=True, text=True,
                          timeout=timeout)


def _cli_error(exc: subprocess.CompletedProcess, fallback: str) -> HTTPException:
    detail = (exc.stderr or exc.stdout or "").strip()[-500:] or fallback
    return HTTPException(status_code=502, detail=f"hermes cron failed: {detail}")


def parse_cron_id(stdout: str, known_ids: set[str] | None = None) -> str | None:
    """Pull the job id out of `hermes cron create` output.

    Prefers an id we already know about (read from jobs.json) appearing in the
    output; otherwise the first id-shaped token. Returns None when the output
    gives us nothing to work with, so the caller can fall back to jobs.json
    rather than inventing an id.
    """
    text = stdout or ""
    for kid in (known_ids or set()):
        if kid and kid in text:
            return kid
    m = CRON_ID_RE.search(text)
    return m.group(1) if m else None


def _cron_job_ids() -> set[str]:
    try:
        data = json.loads(CRON_JOBS.read_text())
        return {str(j.get("id")) for j in data.get("jobs", []) if j.get("id")}
    except Exception:
        return set()


@app.post("/api/v1/cron")
def create_cron(body: dict):
    schedule = (body.get("schedule") or "").strip()
    prompt = (body.get("prompt") or "").strip()
    name = (body.get("name") or "").strip()[:120]
    deliver = (body.get("deliver") or "").strip()
    if not schedule:
        raise HTTPException(status_code=400, detail="schedule required (e.g. 'every 2h', '0 9 * * *')")
    if not prompt and not body.get("script"):
        raise HTTPException(status_code=400, detail="prompt required")
    before = _cron_job_ids()
    args = ["cron", "create", schedule]
    if prompt:
        args.append(prompt)
    if name:
        args += ["--name", name]
    if deliver:
        args += ["--deliver", deliver]
    try:
        proc = _hermes_cli(args)
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="hermes cron create timed out")
    if proc.returncode != 0:
        raise _cli_error(proc, "create failed")
    new_id = parse_cron_id(proc.stdout, known_ids=_cron_job_ids() - before)
    for j in cron():
        if new_id and j["id"] == new_id:
            return j
    if name:
        for j in cron():
            if j["name"] == name:
                return j
    raise HTTPException(status_code=502,
                        detail="job was created but its id could not be read back")


@app.post("/api/v1/cron/{job_id}")
def update_cron(job_id: str, body: dict):
    if job_id not in _cron_job_ids():
        raise HTTPException(status_code=404, detail="cron job not found")
    args = ["cron", "edit", job_id]
    if (sched := (body.get("schedule") or "").strip()):
        args += ["--schedule", sched]
    if (name := (body.get("name") or "").strip()):
        args += ["--name", name[:120]]
    if (prompt := (body.get("prompt") or "").strip()):
        args += ["--prompt", prompt]
    if (deliver := (body.get("deliver") or "").strip()):
        args += ["--deliver", deliver]
    if len(args) == 3:
        raise HTTPException(status_code=400, detail="nothing to update")
    try:
        proc = _hermes_cli(args)
        if proc.returncode != 0:
            raise _cli_error(proc, "edit failed")
        if "enabled" in body:
            verb = "resume" if body.get("enabled") else "pause"
            proc2 = _hermes_cli(["cron", verb, job_id])
            if proc2.returncode != 0:
                raise _cli_error(proc2, f"{verb} failed")
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="hermes cron edit timed out")
    for j in cron():
        if j["id"] == job_id:
            return j
    return {"ok": True}


@app.delete("/api/v1/cron/{job_id}")
def delete_cron(job_id: str):
    if job_id not in _cron_job_ids():
        raise HTTPException(status_code=404, detail="cron job not found")
    try:
        proc = _hermes_cli(["cron", "remove", job_id])
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="hermes cron remove timed out")
    if proc.returncode != 0:
        raise _cli_error(proc, "remove failed")
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


@app.post("/api/v1/skills/{skill_id}/toggle")
def toggle_skill(skill_id: str):
    """Not supported — answer honestly instead of 405-ing into the void.

    Hermes has no per-skill enable/disable flag (skills are directories under
    ~/.hermes/skills and the loader globs them; profiles opt out wholesale via
    `hermes skills opt-out`). The app's Skills screen used to POST here and the
    UI swallowed the 405, so flipping a switch looked like it worked. Now the
    client gets a real message it can show. Disabling one skill is done by
    removing it: `hermes skills uninstall <name>`.
    """
    raise HTTPException(
        status_code=501,
        detail=("this bridge cannot toggle a single skill: Hermes has no per-skill "
                "enable flag. Use `hermes skills uninstall <name>` to remove one."),
    )


def _mem_dir(profile: str | None = None) -> Path:
    """Each profile has its own memory (a project's agent remembers its repo)."""
    try:
        name = named_profile(profile)
    except ValueError:
        raise HTTPException(status_code=400, detail="invalid profile")
    return MEM_DIR if name is None else PROFILES_DIR / name / "memories"


@app.get("/api/v1/memory")
def memory(profile: str | None = None):
    out = []
    mem_dir = _mem_dir(profile)
    for fname, cat in (("USER.md", "user"), ("MEMORY.md", "memory")):
        f = mem_dir / fname
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
def memory_search(q: str = "", profile: str | None = None):
    return [m for m in memory(profile) if q.lower() in m["content"].lower()]


# --- memory writes ----------------------------------------------------------
# The app's Memory screen could add/delete entries, but the bridge only ever
# implemented GET, so every save died on a 405 that the UI swallowed. These are
# file-backed (memories/USER.md, memories/MEMORY.md), written atomically so a
# crash mid-write cannot truncate live memory.
def _memory_category(category: str, profile: str | None = None) -> tuple[str, Path]:
    cat = (category or "").strip().lower()
    mem_dir = _mem_dir(profile)
    if cat in ("user", "user.md"):
        return "user", mem_dir / "USER.md"
    if cat in ("memory", "mem", "memory.md", ""):
        return "memory", mem_dir / "MEMORY.md"
    raise HTTPException(status_code=400, detail="category must be 'user' or 'memory'")


def _memory_entries(category: str, profile: str | None = None) -> list[str]:
    _, path = _memory_category(category, profile)
    if not path.exists():
        return []
    return [e.strip() for e in re.split(r"\n\s*§\s*\n", path.read_text(errors="ignore")) if e.strip()]


def _write_memory_entries(category: str, entries: list[str], profile: str | None = None) -> None:
    _, path = _memory_category(category, profile)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text("\n\n§\n\n".join(entries) + ("\n" if entries else ""))
    os.replace(tmp, path)


@app.post("/api/v1/memory")
def add_memory(body: dict):
    profile = body.get("profile") or None
    category, _ = _memory_category(body.get("category") or "", profile)
    content = (body.get("content") or "").strip()
    if not content:
        raise HTTPException(status_code=400, detail="content required")
    if len(content) > 2000:
        raise HTTPException(status_code=400, detail="content too long (2000 char max)")
    entries = _memory_entries(category, profile)
    entries.append(content)
    _write_memory_entries(category, entries, profile)
    return {
        "id": f"{category}-{len(entries) - 1}",
        "category": category,
        "content": content,
        "createdAt": dt.datetime.now().isoformat(),
    }


@app.delete("/api/v1/memory/{entry_id}")
def delete_memory(entry_id: str, profile: str | None = None):
    m = re.fullmatch(r"(user|memory)-(\d+)", entry_id or "")
    if not m:
        raise HTTPException(status_code=400, detail="id must look like 'user-3' or 'memory-0'")
    category, idx = m.group(1), int(m.group(2))
    entries = _memory_entries(category, profile)
    if idx >= len(entries):
        raise HTTPException(status_code=404, detail="memory entry not found")
    entries.pop(idx)
    _write_memory_entries(category, entries, profile)
    return {"ok": True}


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
    con = _db(_session_owner(session_id) if session_id else None)
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
    }, *_load_servers()]


# --- server profiles --------------------------------------------------------
# The app's "Servers & agents" screen adds and removes servers; the bridge only
# implemented GET, so Add/Delete were 405s that the UI swallowed (the row simply
# reappeared). Extra profiles now persist in $HERMES/mercury_servers.json, and
# the built-in bridge entry is synthetic — it cannot be deleted.
SERVER_STORE = HERMES / "mercury_servers.json"
BUILTIN_SERVER_ID = "srv-hermes"


def _load_servers() -> list[dict]:
    try:
        data = json.loads(SERVER_STORE.read_text())
        items = data.get("servers", [])
        return [s for s in items if isinstance(s, dict) and s.get("id")]
    except Exception:
        return []


def _save_servers(items: list[dict]) -> None:
    SERVER_STORE.parent.mkdir(parents=True, exist_ok=True)
    tmp = SERVER_STORE.with_name(SERVER_STORE.name + ".tmp")
    tmp.write_text(json.dumps({"servers": items}, indent=2))
    os.replace(tmp, SERVER_STORE)


def _validate_server(body: dict) -> dict:
    name = (body.get("name") or "").strip()[:80]
    base = (body.get("baseUrl") or "").strip().rstrip("/")
    if not name:
        raise HTTPException(status_code=400, detail="name required")
    if not base.lower().startswith(("http://", "https://")):
        raise HTTPException(status_code=400, detail="baseUrl must start with http:// or https://")
    bots = body.get("bots")
    return {
        "id": (body.get("id") or "").strip() or f"srv-{int(_now())}",
        "name": name,
        "baseUrl": base,
        "isDefault": bool(body.get("isDefault", False)),
        "accent": int(body.get("accent") or _hash_color(name)),
        "bots": [b for b in bots if isinstance(b, dict)] if isinstance(bots, list) else [],
    }


@app.post("/api/v1/servers")
def add_server(body: dict):
    srv = _validate_server(body)
    if srv["id"] == BUILTIN_SERVER_ID:
        raise HTTPException(status_code=400, detail="srv-hermes is the built-in bridge entry")
    items = [s for s in _load_servers() if s["id"] != srv["id"]]
    items.insert(0, srv)
    _save_servers(items)
    return srv


@app.patch("/api/v1/servers/{server_id}")
def edit_server(server_id: str, body: dict):
    if server_id == BUILTIN_SERVER_ID:
        raise HTTPException(status_code=400, detail="the built-in bridge entry cannot be edited")
    items = _load_servers()
    idx = next((i for i, s in enumerate(items) if s["id"] == server_id), None)
    if idx is None:
        raise HTTPException(status_code=404, detail="server not found")
    merged = {**items[idx], **body, "id": server_id}
    items[idx] = _validate_server(merged)
    _save_servers(items)
    return items[idx]


@app.post("/api/v1/servers/{server_id}")
def save_server(server_id: str, body: dict):
    """Update alias — the Dart client posts to /servers/{id} for edits."""
    if any(s["id"] == server_id for s in _load_servers()):
        return edit_server(server_id, body)
    body = {**body, "id": server_id}
    return add_server(body)


@app.delete("/api/v1/servers/{server_id}")
def delete_server(server_id: str):
    if server_id == BUILTIN_SERVER_ID:
        raise HTTPException(status_code=400, detail="the built-in bridge entry cannot be removed")
    items = _load_servers()
    if not any(s["id"] == server_id for s in items):
        raise HTTPException(status_code=404, detail="server not found")
    _save_servers([s for s in items if s["id"] != server_id])
    return {"ok": True}


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
# Tasker endpoints: triggerable Hermes tasks via HTTP (docs/tasker-endpoints.md)
# ---------------------------------------------------------------------------
def _build_scan_vault_prompt(path: str | None = None, mode: str | None = None, note: str | None = None) -> str:
    vault_target = path or "vault"
    prompt = (
        f"Scan my Obsidian vault at {vault_target}. Summarize what's new or changed, "
        "list any TODO/checklist items, and write/update an index note. Be concise."
    )
    if mode:
        prompt += f" Mode: {mode}."
    if note:
        prompt += f" Context: {note}."
    return prompt


def _build_daily_digest_prompt(path: str | None = None, mode: str | None = None, note: str | None = None) -> str:
    prompt = (
        "Generate a daily digest summarizing today's key tasks, upcoming events, and recent notes. "
        "Be concise and actionable."
    )
    if path:
        prompt += f" Check files at {path}."
    if mode:
        prompt += f" Mode: {mode}."
    if note:
        prompt += f" Context: {note}."
    return prompt


TASK_REGISTRY = {
    "scan_vault": {
        "description": "Scan the markdown vault and summarize changes",
        "builder": _build_scan_vault_prompt,
        "requires_vault": True,
    },
    "daily_digest": {
        "description": "Generate a daily digest of tasks, events, and notes",
        "builder": _build_daily_digest_prompt,
        "requires_vault": False,
    },
}


def _extract_answer(stdout: str) -> str:
    """Extract clean answer text from hermes chat -q stdout."""
    clean = _ANSI_RE.sub("", stdout)
    boxes = re.findall(r"╭─[^\n]+╮\n(.*?)\n╰─[^\n]+╯", clean, re.DOTALL)
    if boxes:
        return strip_cli_plumbing(boxes[-1])
    clean = re.sub(r"^Query:.*?Initializing agent\.\.\.\s*", "", clean, flags=re.DOTALL)
    return strip_cli_plumbing(clean)


@app.get("/api/v1/tasker/tasks")
def tasker_tasks():
    """Return registered task names and one-line descriptions."""
    return {
        "tasks": [
            {"name": name, "description": meta["description"]}
            for name, meta in TASK_REGISTRY.items()
        ]
    }


@app.post("/api/v1/tasker/run")
def tasker_run(body: dict | None = None):
    """Trigger a registered Hermes task.

    Async by default: spawns `hermes chat -q <prompt> --pass-session-id` in a
    background thread, parses stdout for session id, and returns 202 immediately.
    If wait=true, runs synchronously with a bounded timeout (~180s) and returns answer.
    """
    body = body or {}
    task = (body.get("task") or "").strip()
    if not task:
        raise HTTPException(status_code=400, detail="task required")
    if task not in TASK_REGISTRY:
        raise HTTPException(status_code=400, detail=f"unknown task '{task}'")

    task_def = TASK_REGISTRY[task]
    requires_vault = task_def.get("requires_vault", False)

    mer_vault_env = os.environ.get("MER_VAULT_PATH", "").strip()
    path_input = (body.get("path") or "").strip()
    path_str: str | None = None

    if requires_vault or path_input:
        if not mer_vault_env:
            raise HTTPException(
                status_code=400,
                detail="vault not configured — set MER_VAULT_PATH on the bridge",
            )
        vault_root = Path(mer_vault_env).expanduser().resolve()
        if path_input:
            target_path = Path(path_input).expanduser().resolve()
            if not _is_within(target_path, vault_root):
                raise HTTPException(
                    status_code=403,
                    detail="path outside allowed vault root",
                )
            path_str = str(target_path)
        else:
            path_str = str(vault_root)

    mode = (body.get("mode") or "").strip() or None
    note = (body.get("note") or "").strip() or None
    wait = bool(body.get("wait", False))

    builder = task_def["builder"]
    prompt = builder(path=path_str, mode=mode, note=note)

    cmd = [HERMES_BIN, "chat", "-q", prompt, "--pass-session-id"]

    if wait:
        print(f"[tasker] sync run starting: task={task} path={path_str}", flush=True)
        try:
            p = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=180,
                stdin=subprocess.DEVNULL,
            )
        except subprocess.TimeoutExpired:
            raise HTTPException(status_code=504, detail="task execution timed out")
        except Exception as e:
            raise HTTPException(status_code=502, detail=f"hermes failed: {e}")

        out = (p.stdout or "") + "\n" + (p.stderr or "")
        m = re.search(r"Session:\s+([0-9A-Za-z_]+)", out)
        sid = m.group(1) if m else None
        answer = _extract_answer(p.stdout or "")
        print(f"[tasker] sync run finished: task={task} sessionId={sid} path={path_str}", flush=True)
        if task == "scan_vault":
            body_msg = (answer[:200] if answer else "Vault scan complete.")
            _send_push("Vault scan complete", body_msg, {"type": "tasker", "task": task, "session_id": sid or ""})
        return {"ok": True, "answer": answer, "sessionId": sid}

    # Async by default: run in background thread
    session_id_holder: list[str] = []
    session_event = threading.Event()
    out_lines: list[str] = []

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"failed to spawn hermes: {e}")

    def _stream_and_finish():
        try:
            if proc.stdout is not None:
                for line in proc.stdout:
                    out_lines.append(line)
                    if not session_id_holder:
                        m = re.search(r"Session:\s+([0-9A-Za-z_]+)", line)
                        if m:
                            session_id_holder.append(m.group(1))
                            session_event.set()
            proc.wait()
            full_out = "".join(out_lines)
            if not session_id_holder:
                m = re.search(r"Session:\s+([0-9A-Za-z_]+)", full_out)
                if m:
                    session_id_holder.append(m.group(1))
            session_event.set()

            sid = session_id_holder[0] if session_id_holder else None
            print(f"[tasker] async run finished: task={task} sessionId={sid} path={path_str}", flush=True)
            if task == "scan_vault":
                answer = _extract_answer(full_out)
                body_msg = (answer[:200] if answer else "Vault scan complete.")
                _send_push("Vault scan complete", body_msg, {"type": "tasker", "task": task, "session_id": sid or ""})
        except Exception as e:
            print(f"[tasker] background worker error: {e}", flush=True)
            session_event.set()

    t = threading.Thread(target=_stream_and_finish, daemon=True)
    t.start()

    session_event.wait(timeout=25.0)
    if proc.poll() is not None and proc.returncode != 0 and not session_id_holder:
        err_snippet = ("".join(out_lines)).strip()[:200]
        raise HTTPException(status_code=502, detail=f"hermes failed ({proc.returncode}): {err_snippet}")

    sid = session_id_holder[0] if session_id_holder else None
    if not sid:
        import uuid
        sid = dt.datetime.now().strftime("%Y%m%d_%H%M%S") + "_" + uuid.uuid4().hex[:6]

    print(f"[tasker] returning 202: task={task} sessionId={sid} path={path_str}", flush=True)
    resp_data = {"ok": True, "task": task, "sessionId": sid}
    if path_str is not None:
        resp_data["path"] = path_str
    return JSONResponse(status_code=202, content=resp_data)


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


# ---------------------------------------------------------------------------
# Lumen Coach budget & push endpoints (R10-1)
# ---------------------------------------------------------------------------
class SparkyConfigError(Exception):
    pass


class SparkyUnreachableError(Exception):
    pass


class SparkyAuthError(Exception):
    """Sparky rejected our bearer token (401/403) — a credential problem.

    Kept distinct from SparkyUnreachableError so a wrong token can never be
    mistaken for a wrong URL or a dead host (the "guessed /api/v1 that caused
    401s" incident).
    """


class SparkyPathError(Exception):
    """Sparky answered, but the endpoint does not exist (404) — a path problem."""


def _coach_now() -> dt.datetime:
    tz_name = (os.environ.get("MER_COACH_TZ") or MER_COACH_TZ or "").strip()
    if tz_name:
        try:
            return dt.datetime.now(zoneinfo.ZoneInfo(tz_name))
        except Exception:
            pass
    return dt.datetime.now().astimezone()


def _first_non_none(d: dict, *keys):
    for k in keys:
        if k in d and d[k] is not None:
            return d[k]
    return None


def _fetch_sparky_json(endpoint: str, base_url: str, token: str, timeout: float = 5.0) -> dict | list | None:
    url = f"{base_url}{endpoint}"
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "X-API-Key": token,
            "User-Agent": "HermesMobile/1.0",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        if 200 <= resp.status < 300:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    return None


def _compute_coach_level_and_message(
    consumed_kcal: int,
    goal_kcal: int,
    remaining_kcal: int,
    percent: float,
    protein_remaining: float | None,
    now: dt.datetime,
    is_today: bool,
) -> tuple[str, str]:
    if percent >= 100.0:
        level = "OVER"
        over = max(0, consumed_kcal - goal_kcal)
        over_text = f"{over:,} over" if over > 0 else "0 left"
        msg = f"🔴 {consumed_kcal:,} / {goal_kcal:,} kcal — {over_text}. Ease off for the rest of today."
    elif percent >= 85.0:
        level = "NEAR_LIMIT"
        msg = f"🟠 {consumed_kcal:,} / {goal_kcal:,} kcal — only {remaining_kcal:,} left. Choose the next meal carefully."
    elif percent >= 60.0:
        level = "WATCH"
        protein_part = ""
        if protein_remaining is not None and protein_remaining > 0:
            protein_part = f" ({round(protein_remaining):,}g protein to go)"
        msg = f"🟡 {consumed_kcal:,} / {goal_kcal:,} kcal · {remaining_kcal:,} left{protein_part}"
    elif is_today and now.hour >= 12 and consumed_kcal > 0:
        level = "MIDDAY_CHECK"
        msg = f"🕛 Halfway through the day: {consumed_kcal:,} / {goal_kcal:,} kcal · {remaining_kcal:,} left."
    else:
        level = "ON_TRACK"
        if goal_kcal > 0:
            msg = f"🟢 {consumed_kcal:,} / {goal_kcal:,} kcal · {remaining_kcal:,} left"
        else:
            msg = f"🟢 {consumed_kcal:,} kcal consumed"

    return level, msg


def _get_coach_budget(date_str: str | None = None) -> dict:
    base_url = (os.environ.get("SPARKY_BASE_URL") or SPARKY_BASE_URL or "https://fit.randalls.cc").rstrip("/")
    token = (os.environ.get("SPARKY_TOKEN") or SPARKY_TOKEN or "").strip()
    if not token:
        raise SparkyConfigError("sparky not configured")

    now = _coach_now()
    today_str = now.strftime("%Y-%m-%d")
    target_date = date_str.strip() if date_str else today_str

    # 1. Goals. One verified endpoint only (docs/coach-budget-endpoint.md) — the
    # old `/api/goals/by-date/{date}` fallback was a guess, and because a 401 was
    # reported as "unreachable" an invented path was indistinguishable from a bad
    # credential. Errors are now split: 401/403 = credentials, 404 = wrong path,
    # anything else = unreachable.
    goals_data = None
    try:
        raw = _fetch_sparky_json(f"/api/goals/for-date?date={target_date}", base_url, token)
        if raw is not None:
            goals_data = raw.get("data", raw) if isinstance(raw, dict) else raw
    except urllib.error.HTTPError as he:
        if he.code in (401, 403):
            raise SparkyAuthError(f"sparky rejected the token (HTTP {he.code})") from he
        if he.code == 404:
            raise SparkyPathError("sparky has no /api/goals/for-date — check the path") from he
        raise SparkyUnreachableError(f"sparky unreachable: HTTP {he.code}") from he
    except Exception as e:
        raise SparkyUnreachableError(f"sparky unreachable: {e}") from e

    # 2. Nutrition
    nutrition_data = None
    try:
        raw = _fetch_sparky_json(f"/api/food-entries/nutrition/today?date={target_date}", base_url, token)
        if raw is not None:
            nutrition_data = raw.get("data", raw) if isinstance(raw, dict) else raw
    except urllib.error.HTTPError as he:
        if he.code in (401, 403):
            raise SparkyAuthError(f"sparky rejected the token (HTTP {he.code})") from he
        raise SparkyUnreachableError(f"sparky unreachable: HTTP {he.code}") from he
    except Exception as e:
        raise SparkyUnreachableError(f"sparky unreachable: {e}") from e

    if goals_data is None and nutrition_data is None:
        raise SparkyUnreachableError("sparky unreachable")

    # 3. Water (tolerate error/null)
    water_data = None
    try:
        raw = _fetch_sparky_json(f"/api/measurements/water-intake/{target_date}", base_url, token)
        if raw is not None:
            water_data = raw.get("data", raw) if isinstance(raw, dict) else raw
    except Exception:
        water_data = None

    goals = goals_data if isinstance(goals_data, dict) else {}
    nutrition = nutrition_data if isinstance(nutrition_data, dict) else {}
    water = water_data if isinstance(water_data, dict) else {}

    cal_goal = _first_non_none(goals, "calories", "total_calories")
    p_goal = _first_non_none(goals, "protein", "total_protein", "protein_g", "proteinG")
    w_goal = _first_non_none(goals, "water_goal_ml", "water_goal", "water_ml", "waterMl")

    cal_consumed = _first_non_none(nutrition, "total_calories", "calories")
    p_consumed = _first_non_none(nutrition, "total_protein", "protein", "protein_g", "proteinG")
    w_consumed = _first_non_none(water, "water_ml", "amount", "total_amount")

    goal_kcal = int(round(float(cal_goal))) if cal_goal is not None else 0
    consumed_kcal = int(round(float(cal_consumed))) if cal_consumed is not None else 0
    remaining_kcal = max(0, goal_kcal - consumed_kcal)

    percent = round((consumed_kcal / goal_kcal) * 100.0, 1) if goal_kcal > 0 else 0.0

    if p_consumed is not None:
        try:
            protein_consumed = round(float(p_consumed), 1)
        except (ValueError, TypeError):
            protein_consumed = 0.0
    elif p_goal is not None:
        protein_consumed = 0.0
    else:
        protein_consumed = None

    if p_goal is not None:
        try:
            protein_goal = round(float(p_goal), 1)
        except (ValueError, TypeError):
            protein_goal = None
    else:
        protein_goal = None

    protein_remaining = (
        max(0.0, round(protein_goal - (protein_consumed or 0.0), 1))
        if protein_goal is not None
        else None
    )

    if w_consumed is not None:
        try:
            water_ml = round(float(w_consumed), 2)
        except (ValueError, TypeError):
            water_ml = 0.0
    elif w_goal is not None:
        water_ml = 0.0
    else:
        water_ml = None

    if w_goal is not None:
        try:
            water_goal_ml = round(float(w_goal), 2)
        except (ValueError, TypeError):
            water_goal_ml = None
    else:
        water_goal_ml = None

    water_remaining_ml = (
        max(0.0, round(water_goal_ml - (water_ml or 0.0), 2))
        if water_goal_ml is not None
        else None
    )

    is_today = (target_date == today_str)
    level, message = _compute_coach_level_and_message(
        consumed_kcal=consumed_kcal,
        goal_kcal=goal_kcal,
        remaining_kcal=remaining_kcal,
        percent=percent,
        protein_remaining=protein_remaining,
        now=now,
        is_today=is_today,
    )

    # Water is shown to the user in fluid ounces (internally everything stays ml).
    def _to_oz(ml_value):
        return None if ml_value is None else round(float(ml_value) / 29.5735, 1)

    return {
        "date": target_date,
        "consumedKcal": consumed_kcal,
        "goalKcal": goal_kcal,
        "remainingKcal": remaining_kcal,
        "percent": percent,
        "proteinConsumed": protein_consumed,
        "proteinGoal": protein_goal,
        "proteinRemaining": protein_remaining,
        "waterMl": water_ml,
        "waterGoalMl": water_goal_ml,
        "waterRemainingMl": water_remaining_ml,
        "waterOz": _to_oz(water_ml),
        "waterGoalOz": _to_oz(water_goal_ml),
        "waterRemainingOz": _to_oz(water_remaining_ml),
        "level": level,
        "message": message,
    }


def _run_scheduled_coach_push() -> None:
    try:
        budget = _get_coach_budget()
        tokens = _load_tokens()
        if not tokens:
            print("[coach] scheduled push: no registered devices", flush=True)
            return
        sent = _send_push("Lumen Coach", budget["message"], {"type": "coach_budget"})
        print(f"[coach] scheduled push sent to {sent} devices: {budget['message']}", flush=True)
    except Exception as e:
        print(f"[coach] scheduled push failed: {e}", flush=True)


async def _coach_scheduler_loop(times_str: str) -> None:
    slots = {s.strip() for s in times_str.split(",") if s.strip()}
    if not slots:
        return
    tz_name = (os.environ.get("MER_COACH_TZ") or MER_COACH_TZ or "").strip()
    print(f"[coach] scheduler started with slots={sorted(slots)} (tz={tz_name or 'system'})", flush=True)
    fired_date: str = ""
    fired_slots: set[str] = set()

    while True:
        try:
            now = _coach_now()
            sleep_s = max(1, 60 - now.second)
            await asyncio.sleep(sleep_s)

            now = _coach_now()
            today_str = now.strftime("%Y-%m-%d")
            if today_str != fired_date:
                fired_date = today_str
                fired_slots.clear()

            current_slot = now.strftime("%H:%M")
            if current_slot in slots and current_slot not in fired_slots:
                fired_slots.add(current_slot)
                print(f"[coach] scheduled slot {current_slot} reached for {today_str}, running push...", flush=True)
                loop = asyncio.get_running_loop()
                await loop.run_in_executor(None, _run_scheduled_coach_push)
        except asyncio.CancelledError:
            break
        except Exception as e:
            print(f"[coach] scheduler error: {e}", flush=True)
            await asyncio.sleep(5)


@app.get("/api/v1/coach/budget")
def coach_budget(date: str | None = None):
    try:
        return _get_coach_budget(date)
    except SparkyConfigError:
        return JSONResponse(status_code=503, content={"error": "sparky not configured"})
    except SparkyAuthError as e:
        # A credential problem is NOT "unreachable" — say so, without echoing the token.
        return JSONResponse(status_code=502, content={"error": f"sparky auth failed: {e}"})
    except SparkyPathError as e:
        return JSONResponse(status_code=502, content={"error": f"sparky path wrong: {e}"})
    except SparkyUnreachableError:
        return JSONResponse(status_code=503, content={"error": "sparky unreachable"})
    except Exception:
        return JSONResponse(status_code=503, content={"error": "sparky unreachable"})


@app.post("/api/v1/coach/push")
def coach_push(body: dict | None = None):
    try:
        req_date = (body or {}).get("date") if body else None
        budget = _get_coach_budget(req_date)
    except SparkyConfigError:
        return JSONResponse(status_code=503, content={"error": "sparky not configured"})
    except SparkyUnreachableError:
        return JSONResponse(status_code=503, content={"error": "sparky unreachable"})
    except Exception:
        return JSONResponse(status_code=503, content={"error": "sparky unreachable"})

    tokens = _load_tokens()
    if not tokens:
        return JSONResponse(
            status_code=200,
            content={"ok": False, "devices": 0, "error": "no registered devices"},
        )

    sent = _send_push("Lumen Coach", budget["message"], {"type": "coach_budget"})
    return {"ok": True, "devices": sent, "message": budget["message"]}


# ---------------------------------------------------------------------------
# Hermes-driven log reconciliation (R15-1)
#
# The launcher posts the day's note lines; the `lumen` agent classifies each one
# (weight / water / food / ignore) and applies it through its SparkyFitness MCP,
# then writes strict JSON that we return to the client.
# ---------------------------------------------------------------------------

SYNC_AGENT_TIMEOUT = int(os.environ.get("MER_SYNC_TIMEOUT_SECONDS", "180") or "180")
SYNC_AGENT_PROFILE = os.environ.get("MER_SYNC_PROFILE", "").strip()


def _sync_profile() -> str:
    return SYNC_AGENT_PROFILE or _chat_profile() or "lumen"


def _build_sync_prompt(date_str: str, entries: list, removed_markers: list, out_path: str) -> str:
    lines = []
    for e in entries:
        if not isinstance(e, dict):
            continue
        idx = e.get("lineIndex")
        t = str(e.get("time") or "?").strip()
        text = str(e.get("text") or "").strip()
        marker = e.get("marker")
        if isinstance(marker, dict) and marker.get("id"):
            marker_txt = (
                f" | existing record: kind={marker.get('kind')} "
                f"id={marker.get('id')} value={marker.get('value')}"
            )
        else:
            marker_txt = " | no existing record"
        lines.append(f"- lineIndex={idx} | time={t} | text: {text!r}{marker_txt}")
    listing = "\n".join(lines) if lines else "(none)"

    gone = []
    for m in removed_markers or []:
        if isinstance(m, dict) and m.get("id"):
            gone.append(f"- kind={m.get('kind')} id={m.get('id')}")
    gone_txt = "\n".join(gone) if gone else "(none)"

    return f"""Reconcile the user's daily log into SparkyFitness using your SparkyFitness MCP tools.

Date: {date_str}

Note lines to reconcile:
{listing}

Records whose note line no longer exists (delete these):
{gone_txt}

For EACH line above decide exactly one kind: weight | water | food | ignored
(ignored = task lines "- [ ]", headings, mood/sleep prose, or anything that was not consumed or logged).

Then act with the MCP:
- weight -> sparky_manage_checkin, action=log_biometrics (entry_date, weight=<number>, weight_unit="lbs" or "kg" exactly as written)
- water  -> sparky_manage_food, action=log_water (amount_ml = oz x 29.5735, entry_date)

FOOD — the hard part. Getting the QUANTITY/UNIT right matters more than the food match:
  1) Resolve a food in this priority order and record the source:
     a. the user's own catalog/history first: sparky_manage_food action=search_food (internal)
     b. sparky_manage_food action=lookup_food_nutrition
     c. action=search_food search_type=broad -> use the returned food_id/variant_id
     d. a web search for branded/packaged items the databases don't know
     e. last resort: action=create_food — and when you create one, give it a REAL serving
        (e.g. serving "1 piece = 140 kcal" or "100 g = 340 kcal"), never a 1-gram serving.
  2) Work out what ONE SERVING of that food actually is, from the lookup text
     (e.g. "57g: 140 kcal" or "Serving Size: 57 g / Energy: 140 kcal" = nutrition per 57 g).
  3) Convert the human quantity in the note into the variant's OWN serving_unit, which is ALWAYS
     the unit shown in the lookup text ("57g: 140 kcal" -> serving unit g; "240ml: 120 kcal" -> ml).
     SparkyFitness computes an entry as quantity / serving_size x calories, so if you pass a
     different unit the number is silently mis-scaled. This is the #1 cause of wrong logs:
       WRONG: log_food(food_name="Sourdough Bread (Panera Bread)", quantity=1, unit="piece")
              -> Sparky computes 1 / 57 x 140 = 2 kcal   (the app shows "1 piece, 2 Cal")
       RIGHT: log_food(food_name="Sourdough Bread (Panera Bread)", quantity=57, unit="g")
              -> 57 / 57 x 140 = 140 kcal
       WRONG: log_food(food_name="...PROTEIN POWDER...", quantity=1, unit="serving")   (serving_size 70 g)
              -> 1 / 70 x 280 = 4 kcal
       RIGHT: quantity=70, unit="g" -> 280 kcal
     Convert with these weights: slice of bread/toast ~= 40 g (or the catalog's own piece size);
     1 egg ~= 50 g; 1 cup ~= 240 ml (cooked veg ~= 125 g, cooked grains ~= 160 g); 1 tbsp ~= 15 g;
     1 tsp ~= 5 g; 1 oz ~= 28.35 g; 1 scoop ~= 30 g unless the product states otherwise;
     ml ~= 1 g for water-based liquids.
     NEVER pass "piece", "slice", "serving" or "cup" unless the variant's serving_unit is EXACTLY
     that word. When in doubt, pass grams.
  4) action=log_food(food_name, quantity=<in the variant's unit>, unit=<that unit>, meal_type from the
     time (breakfast <11:00, lunch <15:00, dinner <20:00, else snacks), entry_date).
     Also report the kcal you expect for the line as "expectedKcal" in the result JSON.

VERIFY EVERY FOOD ENTRY (mandatory):
  - After logging, call action=list_diary(entry_date) and read back each entry you created.
  - Compare the stored kcal with what that amount should be. Anchors: bread slice 60-150 kcal;
    egg 50-90; cup of cooked veg 25-70; scoop of protein 100-180; scoop of pre-workout 0-15;
    8 oz milk 100-180; pizza slice 200-400.
  - If the stored kcal is off by more than ~15% from your expected value, OR is implausible
    (e.g. a solid food logged at <20 kcal, or 3 slices logged as ~3 g), DELETE that entry and
    re-log it correctly (one retry), then verify again.
  - Also verify entries that already existed for a line (marker present): if the stored kcal is
    mis-scaled, fix it the same way even though the note value did not change.
  - Put the final kcal in "value" (e.g. "3 slices ~= 120 g -> 408 kcal") and mention any repair
    in "detail" (e.g. "internal match; corrected serving").

- Deletes: 404 / "not found" on ANY delete means it is already gone = SUCCESS, never a failure.
- Never invent ids: every sparkyId must come from an actual tool response.

Then write STRICT JSON (no markdown fences, no surrounding prose) to this exact path:
{out_path}

Schema:
{{"ok": true,
 "results": [{{"lineIndex": <int>, "kind": "weight|water|food|ignored",
   "action": "created|updated|deleted|skipped|unchanged", "sparkyId": <string|null>,
   "value": "<amount + final kcal>", "detail": "<short source/reason>",
   "expectedKcal": <number|null, your expected kcal for this line>}}],
 "summary": {{"created": <int>, "updated": <int>, "deleted": <int>, "skipped": <int>, "failed": <int>}},
 "messages": ["<short notes, including any entries you corrected>"]}}

Include exactly one result per input lineIndex, plus one per deleted record (use its kind).
When the file is written, reply with a single one-line summary."""


def _run_sync_agent(prompt: str, timeout: int) -> tuple:
    cmd = [HERMES_BIN, "chat", "-q", prompt, "-p", _sync_profile()]
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL,
            timeout=timeout, start_new_session=True,
        )
        return True, (proc.stdout or "") + (proc.stderr or "")
    except subprocess.TimeoutExpired:
        return False, "agent timeout"
    except Exception as e:  # noqa: BLE001
        return False, f"agent error: {e}"


@app.get("/api/v1/coach/sync-logs/health")
def coach_sync_health():
    return {"ok": True, "profile": _sync_profile(), "mcp": True}


# --- Deterministic post-sync verification -------------------------------------------------
# SparkyFitness computes a diary entry as: quantity / serving_size * calories.
# If the entry's unit does not match the variant's serving_unit the value is silently
# mis-scaled (e.g. 1 "piece" against a 57 g variant => 1/57*140 = 2 kcal). The agent
# cannot see that from list_diary, so we verify against the REST rows ourselves and
# ask the agent to repair anything that is off.

def _entry_effective_kcal(entry: dict):
    try:
        q = float(entry.get("quantity") or 0)
        ss = float(entry.get("serving_size") or 0)
        cal = float(entry.get("calories") or 0)
    except (TypeError, ValueError):
        return None
    if ss <= 0:
        return None
    return q / ss * cal


def _fetch_diary_rows(date_str: str) -> dict:
    base_url = (os.environ.get("SPARKY_BASE_URL") or SPARKY_BASE_URL or "https://fit.randalls.cc").rstrip("/")
    token = (os.environ.get("SPARKY_TOKEN") or SPARKY_TOKEN or "").strip()
    if not token:
        return {}
    try:
        rows = _fetch_sparky_json(
            f"/api/food-entries?selectedDate={date_str}", base_url, token, timeout=15.0
        )
    except Exception:  # noqa: BLE001
        return {}
    out = {}
    if isinstance(rows, list):
        for r in rows:
            if isinstance(r, dict) and r.get("id"):
                out[str(r["id"])] = {
                    "name": r.get("food_name"),
                    "quantity": r.get("quantity"),
                    "unit": r.get("unit"),
                    "serving_size": r.get("serving_size"),
                    "serving_unit": r.get("serving_unit"),
                    "effectiveKcal": _entry_effective_kcal(r),
                }
    return out


def _verify_sync_results(date_str: str, results: list) -> tuple:
    """Returns (checked, problems). Empty problems when we cannot verify at all."""
    diary = _fetch_diary_rows(date_str)
    if not diary:
        return [], []
    checked, problems = [], []
    for r in results:
        if not isinstance(r, dict):
            continue
        sid = r.get("sparkyId")
        if not sid or str(sid) not in diary:
            continue
        info = diary[str(sid)]
        eff = info.get("effectiveKcal")
        try:
            exp = float(r["expectedKcal"]) if r.get("expectedKcal") is not None else None
        except (TypeError, ValueError):
            exp = None
        checked.append({"sparkyId": sid, "name": info.get("name"),
                        "effectiveKcal": None if eff is None else round(eff, 1),
                        "expectedKcal": exp})
        if eff is None:
            continue
        off = abs(eff - exp) / exp if (exp and exp > 0) else 0.0
        implausible = 0 < eff < 15 and (exp is None or exp > 30)
        if (exp and exp > 0 and off > 0.20) or implausible:
            problems.append({
                "sparkyId": str(sid), "lineIndex": r.get("lineIndex"), "name": info.get("name"),
                "loggedQuantity": info.get("quantity"), "loggedUnit": info.get("unit"),
                "variantServingSize": info.get("serving_size"),
                "variantServingUnit": info.get("serving_unit"),
                "effectiveKcal": round(eff, 1), "expectedKcal": exp,
            })
    return checked, problems


def _build_repair_prompt(date_str: str, problems: list, out_path: str) -> str:
    items = "\n".join(
        f"- entry id {p['sparkyId']} ({p['name']}): logged as {p['loggedQuantity']} {p['loggedUnit']} "
        f"which Sparky computes as {p['effectiveKcal']} kcal; the variant is "
        f"{p['variantServingSize']} {p['variantServingUnit']} per serving and it should be about "
        f"{p['expectedKcal']} kcal."
        for p in problems
    )
    return f"""Some food entries you logged for {date_str} are mis-scaled and must be fixed.

SparkyFitness computes an entry as quantity / serving_size * calories, so the logged quantity MUST
be expressed in the variant's own serving_unit (usually "g" or "ml"). Passing a human unit such as
"piece", "slice", "serving" or "cup" against a gram-based variant silently divides by the serving size.

Mis-scaled entries:
{items}

For EACH entry above: delete it (sparky_manage_food action=delete_entry, entry_type="food_entry")
and re-log the same food with the quantity converted into the variant's serving_unit
(e.g. a 57 g sourdough slice -> quantity=57, unit="g"; a 70 g protein serving -> quantity=70, unit="g").
Keep the same meal type and date. A 404/"not found" on delete means it is already gone = success.

Then write STRICT JSON to this exact path: {out_path}
Schema: {{"ok": true,
 "results": [{{"sparkyId": "<new entry id>", "action": "created", "oldSparkyId": "<deleted id>",
   "value": "<amount + kcal>", "detail": "serving repair", "expectedKcal": <number>}}],
 "messages": ["<what you corrected>"]}}
Reply with one short line when done."""


@app.post("/api/v1/coach/sync-logs")
async def coach_sync_logs(body: dict | None = None):
    import uuid

    body = body or {}
    date_str = str(body.get("date") or _coach_now().strftime("%Y-%m-%d")).strip()
    entries = body.get("entries") or []
    removed = body.get("removedMarkers") or []
    zero = {"created": 0, "updated": 0, "deleted": 0, "skipped": 0, "failed": 0}
    if not isinstance(entries, list) or not entries:
        return {"ok": True, "results": [], "summary": zero, "messages": []}

    try:
        timeout = int(body.get("timeoutSeconds") or SYNC_AGENT_TIMEOUT)
    except Exception:  # noqa: BLE001
        timeout = SYNC_AGENT_TIMEOUT
    timeout = max(30, min(timeout, 600))

    out_path = f"/tmp/lumen-sync-{uuid.uuid4().hex}.json"
    if os.path.exists(out_path):
        try:
            os.remove(out_path)
        except OSError:
            pass

    prompt = _build_sync_prompt(date_str, entries, removed, out_path)
    loop = asyncio.get_running_loop()
    ok, output = await loop.run_in_executor(None, _run_sync_agent, prompt, timeout)

    payload = None
    try:
        if os.path.exists(out_path):
            with open(out_path, "r", encoding="utf-8") as fh:
                payload = json.loads(fh.read())
    except Exception:  # noqa: BLE001
        payload = None
    finally:
        try:
            os.remove(out_path)
        except OSError:
            pass

    if not isinstance(payload, dict) or not isinstance(payload.get("results"), list):
        return JSONResponse(
            status_code=502,
            content={
                "ok": False,
                "error": "agent produced no result" if ok else output,
                "stdout": (output or "")[-1500:],
            },
        )

    results = payload["results"]
    if not isinstance(payload.get("summary"), dict):
        summary = dict(zero)
        for r in results:
            act = str((r or {}).get("action") or "").lower()
            if act in ("created", "updated", "deleted", "skipped"):
                summary[act] += 1
            elif act == "failed":
                summary["failed"] += 1
        payload["summary"] = summary
    payload.setdefault("ok", True)
    payload.setdefault("messages", [])

    # Deterministic check: Sparky scales by quantity / serving_size * calories, which the
    # agent cannot see via list_diary. Verify against the real rows and repair once.
    checked, problems = _verify_sync_results(date_str, results)
    repaired = 0
    if problems:
        repair_path = f"/tmp/lumen-sync-repair-{uuid.uuid4().hex}.json"
        if os.path.exists(repair_path):
            try:
                os.remove(repair_path)
            except OSError:
                pass
        repair_prompt = _build_repair_prompt(date_str, problems, repair_path)
        await loop.run_in_executor(None, _run_sync_agent, repair_prompt, timeout)
        repair_payload = None
        try:
            if os.path.exists(repair_path):
                with open(repair_path, "r", encoding="utf-8") as fh:
                    repair_payload = json.loads(fh.read())
        except Exception:  # noqa: BLE001
            repair_payload = None
        finally:
            try:
                os.remove(repair_path)
            except OSError:
                pass

        if isinstance(repair_payload, dict):
            fixes = [r for r in (repair_payload.get("results") or []) if isinstance(r, dict)]
            repaired = len(fixes)
            if isinstance(repair_payload.get("messages"), list):
                payload["messages"].extend(str(m) for m in repair_payload["messages"])
            fixed_old_ids = {str(r.get("oldSparkyId")) for r in fixes if r.get("oldSparkyId")}
            if fixed_old_ids:
                results = [r for r in results if str((r or {}).get("sparkyId")) not in fixed_old_ids]
            results.extend(fixes)
            payload["results"] = results

            summary = dict(zero)
            for r in results:
                act = str((r or {}).get("action") or "").lower()
                if act in ("created", "updated", "deleted", "skipped"):
                    summary[act] += 1
                elif act == "failed":
                    summary["failed"] += 1
            payload["summary"] = summary
        checked, problems = _verify_sync_results(date_str, results)

    payload["verification"] = {
        "checked": checked,
        "problems": problems,
        "repaired": repaired,
    }
    if problems:
        payload["messages"].append(
            f"WARNING: {len(problems)} entr(ies) are still mis-scaled after repair — check the serving unit."
        )
    return payload


@app.get("/healthz")
def healthz():
    # Deliberately unauthenticated (a monitor or systemd probe needs it), so it
    # must not disclose anything: it used to return the HERMES_HOME path.
    return {"ok": True}


# ---------------------------------------------------------------------------
# Mercury projects. Read views over what Hermes records, and relays into Hermes.
# Hermes decides and acts (hermes/ in this repo: skills, scripts, kanban, cron);
# nothing in this section writes to GitHub, a kanban board or the registry.
# ---------------------------------------------------------------------------
MERCURY_DIR = HERMES / "mercury"
MERCURY_BIN = MERCURY_DIR / "bin"
_EVENTS: list[dict] = []
_EVENTS_LOCK = threading.Lock()
_EVENT_LIMIT = 200
_EVENTS_CHANNEL = "mercury:events"
_NOTIFY_KINDS = ("ready", "needs_you", "working", "merged", "info")
_PUSHED_KINDS = ("ready", "needs_you", "merged", "info")
_LOOPBACK = {"127.0.0.1", "::1"}  # /internal/notify callers: Hermes on this host only

_PLAN_SYSTEM = (
    "Mercury Plan mode for project {id} ({repo}). Load and follow the `issue-planner` skill. "
    "This turn is READ-ONLY: read and search code, git log and existing issues only; do not edit "
    "files, run builds, commit, push or file anything. When the scope is clear, end your reply "
    "with one ```issue-draft JSON block."
)

# kanban status -> the phase the app shows, before Mercury's own task state refines it
_PHASE_FROM_STATUS = {"triage": "queued", "todo": "queued", "ready": "queued", "scheduled": "queued",
                      "running": "working", "review": "review", "blocked": "needs_you",
                      "done": "done", "archived": "cancelled"}
_STATUS_ORDER = ("needs_you", "ready", "working", "queued", "idle")


def _mercury_projects() -> list[dict]:
    try:
        return json.loads((MERCURY_DIR / "projects.json").read_text()).get("projects", [])
    except (OSError, ValueError):
        return []


def _project_or_404(pid: str) -> dict:
    for p in _mercury_projects():
        if p["id"] == pid:
            return p
    raise HTTPException(status_code=404, detail=f"no linked project {pid!r}")


def _project_for(pid: str | None, profile: str | None) -> dict:
    """The project a Plan-mode turn belongs to: named, or the one run by `profile`."""
    if pid:
        return _project_or_404(pid)
    for p in _mercury_projects():
        if p.get("profile") == profile:
            return p
    raise HTTPException(status_code=400, detail="Plan mode needs a linked project")


def _task_phase(status: str, state: dict) -> str:
    phase = state.get("phase")
    if status == "running":
        return "working"
    if status == "blocked":
        return "needs_you"
    if phase in ("ready", "merged", "closed", "needs_you") and status in ("review", "done", "archived"):
        return phase
    if status == "review":
        return phase if phase in ("review", "ci_retry") else "review"
    return _PHASE_FROM_STATUS.get(status, "queued")


def _board_tasks(project: dict) -> list[dict]:
    db = HERMES / "kanban" / "boards" / project["board"] / "kanban.db"
    if not db.exists():
        return []
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    try:
        rows = con.execute(
            """SELECT id, title, status, created_at, started_at, completed_at, branch_name,
                      idempotency_key, last_failure_error
               FROM tasks WHERE status != 'archived' OR created_at > ?
               ORDER BY created_at DESC LIMIT 100""", (_now() - 7 * 86400,)).fetchall()
    finally:
        con.close()
    out = []
    for r in rows:
        state = {}
        try:
            state = json.loads((MERCURY_DIR / "tasks" / f"{r['id']}.json").read_text())
        except (OSError, ValueError):
            pass
        out.append({
            "id": r["id"],
            "title": state.get("title") or r["title"],
            "status": r["status"],
            "phase": _task_phase(r["status"], state),
            "issue": state.get("issue"),
            "issueUrl": state.get("issueUrl"),
            "prNumber": state.get("prNumber"),
            "prUrl": state.get("prUrl"),
            "ci": state.get("ci"),
            "failingChecks": state.get("failingChecks") or [],
            "apk": state.get("apk"),
            "coder": state.get("coder") or project.get("coder"),
            "branch": r["branch_name"],
            "blockedReason": state.get("blockedReason") or r["last_failure_error"],
            "mergedAt": _iso(state.get("mergedAt")),
            "createdAt": _iso(r["created_at"]),
            "updatedAt": _iso(state.get("updatedAt") or r["completed_at"] or r["started_at"] or r["created_at"]),
        })
    return out


def _project_view(project: dict, tasks: list[dict] | None = None) -> dict:
    tasks = _board_tasks(project) if tasks is None else tasks
    counts: dict[str, int] = {}
    for t in tasks:
        counts[t["phase"]] = counts.get(t["phase"], 0) + 1
    active = {"needs_you": counts.get("needs_you", 0), "ready": counts.get("ready", 0),
              "working": sum(counts.get(k, 0) for k in ("working", "review", "ci_retry")),
              "queued": counts.get("queued", 0)}
    status = next((k for k in _STATUS_ORDER[:-1] if active.get(k)), "idle")
    return {
        "id": project["id"], "name": project.get("name", project["id"]), "repo": project["repo"],
        "profile": project["profile"], "coder": project.get("coder", "claude"),
        "gates": project.get("gates", ""), "defaultBranch": project.get("defaultBranch", "main"),
        "idleSleepMinutes": project.get("idleSleepMinutes", 10),
        "status": status, "counts": active, "awake": active["working"] > 0,
        "lastTask": tasks[0] if tasks else None, "color": _hash_color(project["id"]),
    }


@app.get("/api/v1/projects")
def projects():
    return [_project_view(p) for p in _mercury_projects()]


@app.get("/api/v1/projects/{pid}")
def project_detail(pid: str):
    project = _project_or_404(pid)
    tasks = _board_tasks(project)
    return {**_project_view(project, tasks), "tasks": tasks}


@app.get("/api/v1/projects/{pid}/tasks")
def project_tasks(pid: str):
    return _board_tasks(_project_or_404(pid))


@app.get("/api/v1/projects/{pid}/sessions")
def project_sessions(pid: str):
    project = _project_or_404(pid)
    if not _profile_db_path(project["profile"]).exists():
        return []
    return _list_sessions([project["profile"]])


# ---- Project notes -------------------------------------------------------------
# Yours, not the agent's. Memory (memories/MEMORY.md) is injected into the
# agent's prompt on every turn, so anything parked there costs tokens forever
# and can steer it. A note is inert: it lives beside the registry, is never
# sent to a model, and only leaves the app when you tap "Ask the agent".
NOTES_DIR = MERCURY_DIR / "notes"
_NOTE_LIMIT = 8000


def _notes_path(pid: str) -> Path:
    return NOTES_DIR / f"{pid}.json"


def _load_notes(pid: str) -> list[dict]:
    try:
        data = json.loads(_notes_path(pid).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    notes = data.get("notes") if isinstance(data, dict) else data
    return [n for n in notes or [] if isinstance(n, dict) and n.get("id")]


def _save_notes(pid: str, notes: list[dict]) -> None:
    """Atomic: a crash mid-write must not lose notes the user typed."""
    NOTES_DIR.mkdir(parents=True, exist_ok=True)
    dest = _notes_path(pid)
    tmp = dest.with_suffix(".json.tmp")
    tmp.write_text(json.dumps({"project": pid, "notes": notes}, indent=2), encoding="utf-8")
    os.replace(tmp, dest)


def _note_text(body: dict | None) -> str:
    text = str((body or {}).get("text") or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="text required")
    if len(text) > _NOTE_LIMIT:
        raise HTTPException(status_code=400, detail=f"note too long ({_NOTE_LIMIT} char max)")
    return text


@app.get("/api/v1/projects/{pid}/notes")
def project_notes(pid: str):
    _project_or_404(pid)
    return _load_notes(pid)


@app.post("/api/v1/projects/{pid}/notes")
def add_project_note(pid: str, body: dict):
    _project_or_404(pid)
    text = _note_text(body)
    notes = _load_notes(pid)
    note = {"id": f"n-{int(time.time() * 1000):x}-{len(notes):x}",
            "text": text, "at": _iso(time.time()), "updatedAt": None}
    notes.append(note)
    _save_notes(pid, notes)
    return note


@app.patch("/api/v1/projects/{pid}/notes/{note_id}")
def edit_project_note(pid: str, note_id: str, body: dict):
    _project_or_404(pid)
    text = _note_text(body)
    notes = _load_notes(pid)
    for n in notes:
        if n.get("id") == note_id:
            n["text"], n["updatedAt"] = text, _iso(time.time())
            _save_notes(pid, notes)
            return n
    raise HTTPException(status_code=404, detail="note not found")


@app.delete("/api/v1/projects/{pid}/notes/{note_id}")
def delete_project_note(pid: str, note_id: str):
    _project_or_404(pid)
    notes = _load_notes(pid)
    kept = [n for n in notes if n.get("id") != note_id]
    if len(kept) == len(notes):
        raise HTTPException(status_code=404, detail="note not found")
    _save_notes(pid, kept)
    return {"ok": True}


_REPOS_CACHE: dict = {"at": 0.0, "data": []}


@app.get("/api/v1/github/repos")
def github_repos():
    """Repos the host's gh login can see, for the link sheet (read-only)."""
    if time.time() - _REPOS_CACHE["at"] > 60:
        try:
            p = subprocess.run(["gh", "repo", "list", "--limit", "200", "--json",
                                "nameWithOwner,description,primaryLanguage,updatedAt,isPrivate"],
                               capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise HTTPException(status_code=503, detail=f"gh unavailable: {e}")
        if p.returncode != 0:
            raise HTTPException(status_code=503, detail=(p.stderr or "gh failed").strip()[-300:])
        _REPOS_CACHE.update(at=time.time(), data=json.loads(p.stdout or "[]"))
    linked = {p["repo"].lower(): p["id"] for p in _mercury_projects()}
    return [{"repo": r["nameWithOwner"], "description": r.get("description") or "",
             "language": (r.get("primaryLanguage") or {}).get("name"), "private": r.get("isPrivate", False),
             "updatedAt": r.get("updatedAt"), "linkedAs": linked.get(r["nameWithOwner"].lower())}
            for r in _REPOS_CACHE["data"]]


@app.get("/api/v1/tunnel")
def tunnel():
    """The Cloudflare tunnel reaching this bridge, if there is one (read-only).

    Starting or stopping it is Hermes' job (`mercury_tunnel.py up|down`), not the
    bridge's: this only reports what that script left in ~/.hermes/mercury, so a
    connected app can show the URL to copy to a phone that is off the LAN.
    """
    state = {}
    try:
        state = json.loads((MERCURY_DIR / "tunnel.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        state = {}
    pid = int(state.get("pid") or 0)
    # Liveness by reading /proc, not by signalling: the bridge relays, it does not
    # manage processes (a test enforces that — see test_projects.py).
    alive = False
    if pid > 0:
        try:
            alive = "cloudflared" in Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="ignore")
        except OSError:
            alive = False
    return {"up": alive, "kind": state.get("kind") if alive else None,
            "url": state.get("url") if alive else None,
            "hostname": state.get("hostname") if alive else None,
            "port": state.get("port"), "startedAt": _iso(state.get("startedAt")) if alive else None,
            "accessProtected": bool(state.get("accessProtected")) if alive else False,
            "how": "ask Hermes to start it: [Mercury: tunnel] {\"action\": \"up\"}"}


@app.get("/api/v1/agents")
def agents():
    script = MERCURY_BIN / "mercury_resources.py"
    if not script.exists():
        raise HTTPException(status_code=503, detail="Mercury's Hermes scripts are not installed (hermes/install.sh)")
    p = subprocess.run(["python3", str(script), "snapshot"], capture_output=True, text=True, timeout=20)
    try:
        return json.loads(p.stdout)
    except ValueError:
        raise HTTPException(status_code=502, detail="resource snapshot failed")


def _orchestrator_session() -> str:
    """The default profile's chat that the app pins as "Hermes"; intents land here."""
    path = MERCURY_DIR / "orchestrator.json"
    try:
        sid = json.loads(path.read_text()).get("sessionId")
    except (OSError, ValueError):
        sid = None
    if sid and _session_title(sid) is not None:
        return sid
    if not HERMES_API.available():
        raise HTTPException(status_code=503, detail="the Hermes API server is not reachable")
    try:
        sid = HERMES_API.create_session(title="Hermes · Mercury")
    except HermesApiError as e:
        raise HTTPException(status_code=502, detail=f"could not create the Hermes chat: {e}")
    MERCURY_DIR.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps({"sessionId": sid}))
    os.replace(tmp, path)
    return sid


@app.get("/api/v1/orchestrator")
def orchestrator():
    return {"sessionId": _orchestrator_session(), "profileId": "hermes", "title": "Hermes"}


# What the app may ask Hermes to do. The text is what Hermes sees; the
# mercury-orchestrator / issue-planner skills say how to act on each one.
# `edit_task` goes to the orchestrator (it owns the board); `file_issue` and
# `followup_issue` go to the project agent (it owns the repo and its memory).
_INTENTS = {
    "link_repo": "link repo", "set_project": "set project", "unlink": "unlink",
    "retry_task": "retry task", "cancel_task": "cancel task", "pause": "pause", "resume": "resume",
    "file_issue": "file issue", "edit_task": "edit task", "followup_issue": "follow-up issue",
    "tunnel": "tunnel",
}
_PROJECT_INTENTS = ("file_issue", "followup_issue")


def _project_session(project: dict, session_id: str | None = None) -> tuple[str, str]:
    """The project chat an intent lands in: the app's session, the newest one, or a new one.

    A suggestion about a task belongs in the project's own chat, so the agent has
    the repo, its memory and the issue in front of it.
    """
    profile = project["profile"]
    if session_id and _session_title(session_id, profile) is not None:
        return session_id, profile
    existing = _list_sessions([profile])
    if existing:
        return existing[0]["id"], profile
    if not (HERMES_API.serves(profile) and HERMES_API.available()):
        raise HTTPException(status_code=503, detail="the Hermes API server does not serve this project")
    try:
        sid = HERMES_API.create_session(title=f"{project['name']} · Mercury", profile=profile)
    except HermesApiError as e:
        raise HTTPException(status_code=502, detail=f"could not start the project chat: {e}")
    return sid, profile


@app.post("/api/v1/hermes/intent")
def hermes_intent(body: dict):
    kind = body.get("kind") or ""
    if kind not in _INTENTS:
        raise HTTPException(status_code=400, detail=f"unknown intent {kind!r}")
    payload = body.get("payload") or {}
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="payload must be an object")
    if kind in _PROJECT_INTENTS:
        # goes to the project agent: it owns the repo, the plan chat and its memory
        project = _project_or_404(body.get("project") or "")
        if kind == "file_issue":
            sid, profile = body.get("sessionId") or "", project["profile"]
            if not sid:
                raise HTTPException(status_code=400, detail="file_issue needs the Plan chat's sessionId")
            text = f"[Mercury Plan · project {project['id']} · {project['repo']}]\n[Mercury: file issue] " \
                   + json.dumps(payload.get("draft") or payload)
        else:
            # a suggestion about work that already shipped: a follow-up issue
            sid, profile = _project_session(project, body.get("sessionId"))
            text = f"[Mercury: {_INTENTS[kind]}] " + json.dumps(
                {"project": project["id"], "repo": project["repo"], **payload})
    else:
        if body.get("project"):
            payload = {"project": body["project"], **payload}
        sid, profile = _orchestrator_session(), None
        text = f"[Mercury: {_INTENTS[kind]}] {json.dumps(payload)}"
    if not HERMES_API.serves(profile) or not HERMES_API.available():
        raise HTTPException(status_code=503, detail="the Hermes API server is not reachable")
    try:
        result = HERMES_API.chat(sid, text, timeout=300, profile=profile)
    except HermesApiError as e:
        raise HTTPException(status_code=502, detail=f"hermes failed: {e}")
    return {"sessionId": result["session_id"], "reply": result["content"], "kind": kind}


def _notify_key() -> str:
    try:
        return (MERCURY_DIR / "notify.key").read_text().strip()
    except OSError:
        return ""


@app.post("/internal/notify")
async def internal_notify(request: Request):
    """Hermes (mercury_notify.py) -> the phone. Loopback only, with the notify key
    install.sh created; the app's bearer token is not accepted here."""
    host = request.client.host if request.client else ""
    key = _notify_key()
    supplied = request.headers.get("X-Mercury-Notify-Key", "")
    if host not in _LOOPBACK or not key or not hmac.compare_digest(supplied.encode(), key.encode()):
        raise HTTPException(status_code=403, detail="forbidden")
    body = await request.json()
    kind = body.get("kind")
    if kind not in _NOTIFY_KINDS:
        raise HTTPException(status_code=400, detail="bad kind")
    import uuid

    event = {
        "id": uuid.uuid4().hex[:12], "at": _iso(_now()), "kind": kind,
        "project": str(body.get("project") or "")[:80], "task": body.get("task"),
        "title": str(body.get("title") or "")[:200], "body": str(body.get("body") or "")[:1000],
        "url": body.get("url"), "apk": body.get("apk"),
    }
    with _EVENTS_LOCK:
        _EVENTS.append(event)
        del _EVENTS[:-_EVENT_LIMIT]
    _broadcast(_EVENTS_CHANNEL, {"event": "project_event", **event})
    pushed = 0
    if kind in _PUSHED_KINDS:
        pushed = _send_push(event["title"], event["body"] or event["title"],
                            {"type": "project", "kind": kind, "project": event["project"],
                             "task": event["task"] or "", "url": event["url"] or "", "apk": event["apk"] or ""})
    return {"ok": True, "id": event["id"], "pushed": pushed}


@app.get("/api/v1/events")
def events(since: str | None = None):
    with _EVENTS_LOCK:
        items = list(_EVENTS)
    return [e for e in items if not since or e["at"] > since]


@app.websocket("/ws/events")
async def ws_events(websocket: WebSocket):
    if not _token_ok(_request_token(websocket)):
        await websocket.close(code=1008)
        return
    await websocket.accept()
    q: asyncio.Queue = asyncio.Queue()
    _register_queue(_EVENTS_CHANNEL, q)
    try:
        while True:
            await websocket.send_text(json.dumps(await q.get()))
    except WebSocketDisconnect:
        pass
    finally:
        _unregister_queue(_EVENTS_CHANNEL, q)


if __name__ == "__main__":
    import uvicorn

    if BRIDGE_HOST not in ("127.0.0.1", "::1", "localhost"):
        print(
            f"[bridge] SECURITY: listening on {BRIDGE_HOST} (not loopback) over "
            "plain HTTP. The bearer token and every response cross the network in "
            "cleartext — use a Tailscale interface + BRIDGE_HOST=<tailnet ip>, or "
            "put a TLS proxy in front of this port.",
            flush=True,
        )
    uvicorn.run(app, host=BRIDGE_HOST, port=int(os.environ.get("PORT", "9130")))
