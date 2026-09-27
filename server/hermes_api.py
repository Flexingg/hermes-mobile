"""Client for the Hermes gateway's API server (``gateway/platforms/api_server.py``).

The resident Hermes gateway already runs the agent; talking to it over HTTP means a
chat turn no longer pays for a fresh ``hermes chat`` process (startup time plus a
few hundred MB each). This module only relays: it never decides anything, it
turns the API server's SSE events into the chunk contract the app already speaks
(``{"event": "chunk", "type": answer|thinking|technical, "delta": ...}``).

Profiles: with ``gateway.multiplex_profiles`` on, the one gateway also serves every
other profile under ``/p/<profile>/``, and authenticates each with that profile's
own API_SERVER_KEY (it fails closed rather than accept the default key).

Configuration (all optional):
  HERMES_API_URL   default http://127.0.0.1:8642
  HERMES_API_KEY   the default profile's key; default: API_SERVER_KEY read from
                   $HERMES_HOME/.env. A named profile's key is read from
                   $HERMES_HOME/profiles/<name>/.env. Keys are never copied.
"""
from __future__ import annotations

import http.client
import json
import os
import re
import threading
import time
from pathlib import Path
from typing import Callable, Iterator
from urllib.parse import quote, urlsplit

DEFAULT_URL = "http://127.0.0.1:8642"
HEALTH_TTL = 30.0  # seconds a health result is trusted
CONNECT_TIMEOUT = 5.0
TURN_TIMEOUT = 1800.0  # a single agent turn may run tools for a long time
# The note relayed to a running turn when Stop is pressed once. It is a steer,
# not an interrupt: the step in flight finishes, then the model ends the turn.
# Phrased as the user speaking, because that is the role it arrives in.
STOP_STEER_NOTE = (
    "The user pressed Stop. Do not start anything new. Finish the single step you are "
    "on, then end your turn right away with a short summary of where things stand and "
    "what is left unfinished."
)
# What a broken connection or a malformed response can raise. HTTPException
# (BadStatusLine, IncompleteRead, ...) is not an OSError, and letting it escape
# would end the relay thread without the "done" the app is waiting for.
_TRANSPORT_ERRORS = (OSError, http.client.HTTPException)

# These names all mean the gateway's own (default) profile.
_DEFAULT_PROFILE_NAMES = {"", "hermes", "default"}
_PROFILE_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


def named_profile(profile: str | None) -> str | None:
    """None for the default profile, else the validated profile name."""
    name = (profile or "").strip().lower()
    if name in _DEFAULT_PROFILE_NAMES:
        return None
    if not _PROFILE_NAME_RE.match(name):
        raise ValueError(f"invalid profile name: {profile!r}")
    return name


class HermesApiError(Exception):
    """The API server could not take the turn. ``started`` says whether any event
    had already been relayed, which decides whether a fallback is still safe."""

    def __init__(self, message: str, *, status: int = 0, started: bool = False):
        super().__init__(message)
        self.status = status
        self.started = started


def _read_env_key(hermes_home: Path) -> str:
    """API_SERVER_KEY from the Hermes .env: only that one line is parsed."""
    try:
        for line in (hermes_home / ".env").read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("API_SERVER_KEY="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    return ""


class HermesApi:
    def __init__(self, hermes_home: Path, url: str | None = None, key: str | None = None,
                 multiplex: Callable[[], bool] | None = None):
        self.url = (url or os.environ.get("HERMES_API_URL") or DEFAULT_URL).rstrip("/")
        self._hermes_home = hermes_home
        self._key = key if key is not None else os.environ.get("HERMES_API_KEY")
        # Whether the gateway multiplexes profiles; read live, so turning it on or
        # off needs no bridge restart.
        self._multiplex = multiplex or (lambda: False)
        self._health: tuple[float, bool] = (0.0, False)
        self._lock = threading.Lock()

    # -- configuration -------------------------------------------------------
    @property
    def key(self) -> str:
        if self._key is None:
            self._key = _read_env_key(self._hermes_home)
        return self._key or ""

    def key_for(self, profile: str | None) -> str:
        name = named_profile(profile)
        if name is None:
            return self.key
        return _read_env_key(self._hermes_home / "profiles" / name)

    def serves(self, profile: str | None) -> bool:
        """Whether a turn for ``profile`` can go through the API server."""
        try:
            name = named_profile(profile)
        except ValueError:
            return False
        if name is None:
            return True
        # Another profile needs the gateway to multiplex, and its own key.
        return bool(self._multiplex()) and bool(self.key_for(name))

    @staticmethod
    def _prefix(profile: str | None) -> str:
        name = named_profile(profile)
        return "" if name is None else f"/p/{name}"

    def available(self) -> bool:
        """Cached health check; False when no key is configured."""
        if not self.key:
            return False
        with self._lock:
            checked_at, ok = self._health
            if time.monotonic() - checked_at < HEALTH_TTL:
                return ok
        try:
            status, _ = self._request("GET", "/health", timeout=2.0)
            ok = status == 200
        except HermesApiError:
            ok = False
        with self._lock:
            self._health = (time.monotonic(), ok)
        return ok

    def mark_down(self) -> None:
        with self._lock:
            self._health = (time.monotonic(), False)

    # -- HTTP ----------------------------------------------------------------
    def _conn(self, timeout: float) -> http.client.HTTPConnection:
        parts = urlsplit(self.url)
        cls = http.client.HTTPSConnection if parts.scheme == "https" else http.client.HTTPConnection
        return cls(parts.hostname, parts.port, timeout=timeout)

    def _headers(self, profile: str | None = None) -> dict:
        return {"Authorization": f"Bearer {self.key_for(profile)}",
                "Content-Type": "application/json"}

    def _request(self, method: str, path: str, body: dict | None = None,
                 timeout: float = CONNECT_TIMEOUT, profile: str | None = None) -> tuple[int, dict]:
        conn = self._conn(timeout)
        try:
            conn.request(method, self._prefix(profile) + path,
                         body=json.dumps(body) if body is not None else None,
                         headers=self._headers(profile))
            resp = conn.getresponse()
            raw = resp.read()
        except _TRANSPORT_ERRORS as exc:
            self.mark_down()
            raise HermesApiError(f"API server unreachable: {exc}") from exc
        finally:
            conn.close()
        try:
            data = json.loads(raw) if raw else {}
        except ValueError:
            data = {"raw": raw[:500].decode("utf-8", "replace")}
        return resp.status, data

    # -- sessions ------------------------------------------------------------
    def create_session(self, title: str | None = None, profile: str | None = None) -> str:
        body: dict = {"source": "api_server"}
        if title:
            body["title"] = title[:200]
        status, data = self._request("POST", "/api/sessions", body, profile=profile)
        if status not in (200, 201):
            raise HermesApiError(_error_text(data, "could not create session"), status=status)
        session = data.get("session") or data
        sid = session.get("id") or session.get("session_id")
        if not sid:
            raise HermesApiError("API server returned no session id", status=status)
        return sid

    def chat(self, session_id: str, text: str, timeout: float = TURN_TIMEOUT,
             profile: str | None = None, system: str | None = None) -> dict:
        """One synchronous turn; returns ``{"session_id", "content"}``."""
        status, data = self._request(
            "POST", f"/api/sessions/{quote(session_id, safe='')}/chat",
            _turn_body(text, system), timeout=timeout, profile=profile,
        )
        if status != 200:
            raise HermesApiError(_error_text(data, "chat failed"), status=status)
        return {
            "session_id": data.get("session_id") or session_id,
            "content": ((data.get("message") or {}).get("content") or ""),
        }

    def stream_chat(self, session_id: str, text: str, emit: Callable[[dict], None],
                    profile: str | None = None, system: str | None = None,
                    on_run: Callable[[str], None] | None = None) -> None:
        """Run one turn and relay it as bridge chunks through ``emit``.

        Emits ``{"event": "chunk", ...}`` payloads only; the caller sends ``done``.
        ``on_run`` is called once with the run id the gateway assigned to this
        turn (from its ``run.started`` event). That id is the handle
        :meth:`steer_run` and :meth:`stop_run` need to interrupt the turn — the
        gateway exposes no session-keyed stop, so without it a turn can only be
        killed by dropping this connection.
        Raises HermesApiError with ``started=False`` when nothing was relayed yet
        (the caller may fall back to the CLI), ``started=True`` otherwise.
        """
        conn = self._conn(TURN_TIMEOUT)
        started = False
        try:
            try:
                conn.request("POST", self._prefix(profile)
                             + f"/api/sessions/{quote(session_id, safe='')}/chat/stream",
                             body=json.dumps(_turn_body(text, system)), headers=self._headers(profile))
                resp = conn.getresponse()
            except _TRANSPORT_ERRORS as exc:
                self.mark_down()
                raise HermesApiError(f"API server unreachable: {exc}") from exc
            if resp.status != 200:
                raw = resp.read()
                try:
                    data = json.loads(raw) if raw else {}
                except ValueError:
                    data = {}
                raise HermesApiError(_error_text(data, f"HTTP {resp.status}"), status=resp.status)
            for name, payload in iter_sse(resp):
                if name == "run.started" and on_run is not None:
                    run_id = payload.get("run_id")
                    if run_id:
                        on_run(str(run_id))
                chunk = to_chunk(name, payload)
                if chunk is not None:
                    started = True
                    emit(chunk)
                if name == "error":
                    raise HermesApiError(payload.get("message") or "agent run failed", started=True)
                if name == "done":
                    return
            raise HermesApiError("stream ended before the run finished", started=started)
        except _TRANSPORT_ERRORS as exc:
            raise HermesApiError(f"stream interrupted: {exc}", started=started) from exc
        finally:
            conn.close()

    def stream_turn(self, text: str, emit: Callable[[dict], None],
                    profile: str | None = None, system: str | None = None,
                    on_run: Callable[[str], None] | None = None) -> str:
        """One turn for a caller that has no Hermes session of its own.

        The gateway runs every turn against a session, so create one, stream the
        turn into it and hand its id back. Relay contract is stream_chat's:
        HermesApiError with started=False when nothing was relayed yet, so the
        caller can still fall back to the CLI.
        """
        sid = self.create_session(profile=profile)
        self.stream_chat(sid, text, emit, profile=profile, system=system, on_run=on_run)
        return sid


    # -- live turn control ---------------------------------------------------
    def steer_run(self, run_id: str, text: str, profile: str | None = None) -> bool:
        """Inject a note into a running turn without interrupting it.

        The gateway appends it to the next tool result, so the model sees it at
        a role-safe boundary. That is what makes this the *graceful* half of
        Stop: the step in flight finishes, then the model wraps up. False means
        the run already ended or is not accepting steer input — not an error.
        """
        status, data = self._request(
            "POST", f"/v1/runs/{quote(run_id, safe='')}/steer", {"input": text},
            timeout=CONNECT_TIMEOUT, profile=profile,
        )
        if status in (404, 409):
            return False
        if status != 200:
            raise HermesApiError(_error_text(data, "could not steer the run"), status=status)
        return bool(data.get("accepted", True))

    def stop_run(self, run_id: str, profile: str | None = None) -> bool:
        """Hard-stop a running turn: the gateway interrupts it and reaps the
        processes it started. False means the run was already gone."""
        status, data = self._request(
            "POST", f"/v1/runs/{quote(run_id, safe='')}/stop", {},
            timeout=CONNECT_TIMEOUT, profile=profile,
        )
        if status == 404:
            return False
        if status != 200:
            raise HermesApiError(_error_text(data, "could not stop the run"), status=status)
        return True


def _turn_body(text: str, system: str | None) -> dict:
    """A turn; `system` is an extra system message for this turn only (Plan mode)."""
    body = {"message": text}
    if system:
        body["system_message"] = system
    return body


def _error_text(data: dict, fallback: str) -> str:
    err = data.get("error") if isinstance(data, dict) else None
    if isinstance(err, dict) and err.get("message"):
        return str(err["message"])
    if isinstance(data, dict) and data.get("detail"):
        return str(data["detail"])
    return fallback


def iter_sse(resp) -> Iterator[tuple[str, dict]]:
    """Parse ``event:``/``data:`` frames; comments (keepalives) are skipped."""
    event, data_lines = "message", []
    while True:
        raw = resp.readline()
        if not raw:
            return
        line = raw.decode("utf-8", "replace").rstrip("\r\n")
        if line == "":
            if data_lines:
                try:
                    payload = json.loads("\n".join(data_lines))
                except ValueError:
                    payload = {"raw": "\n".join(data_lines)}
                yield event, payload if isinstance(payload, dict) else {"value": payload}
            event, data_lines = "message", []
        elif line.startswith(":"):
            continue
        elif line.startswith("event:"):
            event = line[6:].strip()
        elif line.startswith("data:"):
            data_lines.append(line[5:].lstrip())


def to_chunk(name: str, p: dict) -> dict | None:
    """Map one API-server event to the app's chunk contract (None = not shown)."""
    if name == "assistant.delta":
        delta = p.get("delta") or ""
        return {"event": "chunk", "type": "answer", "delta": delta} if delta else None
    if name == "tool.progress":
        # reasoning arrives as tool.progress with the synthetic "_thinking" tool
        if (p.get("tool_name") or "") == "_thinking":
            delta = p.get("delta") or ""
            return {"event": "chunk", "type": "thinking", "delta": delta} if delta else None
        return None
    if name in ("tool.started", "tool.completed", "tool.failed"):
        tool = p.get("tool_name") or "tool"
        if name == "tool.completed":
            return None  # one line per tool call is enough; failures still show
        mark = "┊" if name == "tool.started" else "✖"
        preview = (p.get("preview") or "").strip().replace("\n", " ")[:160]
        return {"event": "chunk", "type": "technical",
                "delta": f"{mark} {tool}{(' ' + preview) if preview else ''}\n"}
    if name == "error":
        return {"event": "chunk", "type": "technical",
                "delta": f"⚠ {p.get('message') or 'agent run failed'}\n"}
    return None
