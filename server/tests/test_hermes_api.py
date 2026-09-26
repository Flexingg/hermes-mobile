"""The bridge relays chat to the Hermes API server and falls back to the CLI.

A small in-process HTTP server stands in for the gateway's API server, speaking
the same SSE event names (`gateway/platforms/api_server.py`), so every path here
runs offline.
"""
import json
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

import bridge
from conftest import auth
from hermes_api import HermesApi, HermesApiError, iter_sse, to_chunk

KEY = "k" * 32


def sse(event: str, payload: dict) -> bytes:
    return f"event: {event}\ndata: {json.dumps(payload)}\n\n".encode()


GOOD_RUN = [
    b": keepalive\n\n",
    sse("run.started", {"user_message": {"role": "user", "content": "hi"}}),
    sse("tool.progress", {"tool_name": "_thinking", "delta": "pondering"}),
    sse("tool.started", {"tool_name": "terminal", "preview": "ls -la"}),
    sse("tool.completed", {"tool_name": "terminal"}),
    sse("assistant.delta", {"delta": "Hel"}),
    sse("assistant.delta", {"delta": "lo"}),
    sse("assistant.completed", {"content": "Hello"}),
    sse("run.completed", {"completed": True}),
    sse("done", {}),
]


class FakeApi:
    """Records requests; `script` decides what each stream returns."""

    def __init__(self):
        self.requests = []
        self.stream = GOOD_RUN
        self.stream_status = 200
        self.sessions = {"s1"}

    def start(self):
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _body(self):
                n = int(self.headers.get("Content-Length") or 0)
                return json.loads(self.rfile.read(n) or b"{}")

            def _json(self, status, data):
                raw = json.dumps(data).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def _authed(self):
                if self.headers.get("Authorization") != f"Bearer {KEY}":
                    self._json(401, {"error": {"message": "Invalid API key"}})
                    return False
                return True

            def do_GET(self):
                fake.requests.append(("GET", self.path, None))
                if self.path == "/health":
                    return self._json(200, {"status": "ok"})
                self._json(404, {})

            def do_POST(self):
                body = self._body()
                fake.requests.append(("POST", self.path, body))
                if not self._authed():
                    return
                if self.path == "/api/sessions":
                    fake.sessions.add("api_new")
                    return self._json(201, {"object": "hermes.session", "session": {"id": "api_new"}})
                sid = self.path.split("/")[3]
                if sid not in fake.sessions:
                    return self._json(404, {"error": {"message": f"Session not found: {sid}"}})
                if self.path.endswith("/chat/stream"):
                    if fake.stream_status != 200:
                        return self._json(fake.stream_status, {"error": {"message": "boom"}})
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    for frame in fake.stream:
                        self.wfile.write(frame)
                        self.wfile.flush()
                    return
                if self.path.endswith("/chat"):
                    return self._json(200, {"session_id": sid,
                                            "message": {"role": "assistant", "content": "PONG"}})
                self._json(404, {})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        return self

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture
def fake_api(tmp_path, monkeypatch):
    fake = FakeApi().start()
    api = HermesApi(tmp_path, url=fake.url, key=KEY)
    monkeypatch.setattr(bridge, "HERMES_API", api)
    yield fake
    fake.stop()


@pytest.fixture
def broadcasts(monkeypatch):
    """Capture what the bridge sends to /ws/chat listeners."""
    got = []
    done = threading.Event()

    def capture(session_id, payload):
        got.append((session_id, payload))
        if payload.get("event") == "done":
            done.set()

    monkeypatch.setattr(bridge, "_broadcast", capture)
    monkeypatch.setattr(bridge, "_send_chat_reply_push", lambda sid: None)
    return got, done


@pytest.fixture
def cli_calls(monkeypatch):
    calls = []

    def fake_cli(session_id, query, img_path, prof):
        calls.append((session_id, query, img_path, prof))
        bridge._broadcast(session_id, {"event": "done"})

    monkeypatch.setattr(bridge, "_run_hermes_cli", fake_cli)
    return calls


# -- event mapping -----------------------------------------------------------
def test_events_map_to_the_apps_chunk_contract():
    assert to_chunk("assistant.delta", {"delta": "hi"}) == {"event": "chunk", "type": "answer", "delta": "hi"}
    assert to_chunk("tool.progress", {"tool_name": "_thinking", "delta": "hmm"})["type"] == "thinking"
    started = to_chunk("tool.started", {"tool_name": "terminal", "preview": "ls\n-la"})
    assert started["type"] == "technical" and started["delta"] == "┊ terminal ls -la\n"
    assert to_chunk("tool.failed", {"tool_name": "terminal"})["delta"].startswith("✖ terminal")
    assert to_chunk("error", {"message": "rate limited"})["delta"] == "⚠ rate limited\n"
    # lifecycle noise and empty deltas are not shown
    for name, p in [("tool.completed", {"tool_name": "t"}), ("run.started", {}),
                    ("assistant.completed", {"content": "x"}), ("assistant.delta", {"delta": ""}),
                    ("tool.progress", {"tool_name": "terminal", "delta": "x"}), ("done", {})]:
        assert to_chunk(name, p) is None, name


def test_sse_parser_skips_keepalives_and_joins_data_lines():
    class R:
        def __init__(self, raw):
            self.lines = raw.splitlines(keepends=True)

        def readline(self):
            return self.lines.pop(0) if self.lines else b""

    raw = b": keepalive\n\nevent: a\ndata: {\"x\":\ndata: 1}\n\nevent: done\ndata: {}\n\n"
    assert list(iter_sse(R(raw))) == [("a", {"x": 1}), ("done", {})]


# -- the client ----------------------------------------------------------------
def test_key_is_read_from_the_hermes_env_file_only(tmp_path):
    (tmp_path / ".env").write_text("OTHER_TOKEN=nope\nAPI_SERVER_KEY='abc123'\n")
    assert HermesApi(tmp_path).key == "abc123"
    assert HermesApi(tmp_path / "missing").key == ""


def test_no_key_means_not_available_without_any_request(tmp_path, fake_api):
    api = HermesApi(tmp_path, url=fake_api.url, key="")
    assert api.available() is False
    assert fake_api.requests == []


def test_only_the_default_profile_is_served_until_multiplexing(tmp_path):
    api = HermesApi(tmp_path, key=KEY)
    for p in (None, "", "hermes", "default", " Hermes "):
        assert api.serves(p), p
    for p in ("dev-hermes-mobile", "buff-patrick"):
        assert not api.serves(p), p


def test_stream_relays_chunks_in_order(fake_api):
    got = []
    bridge.HERMES_API.stream_chat("s1", "hi", got.append)
    assert [(c["type"], c["delta"]) for c in got] == [
        ("thinking", "pondering"), ("technical", "┊ terminal ls -la\n"),
        ("answer", "Hel"), ("answer", "lo"),
    ]
    assert fake_api.requests[-1] == ("POST", "/api/sessions/s1/chat/stream", {"message": "hi"})


def test_unknown_session_fails_before_anything_is_relayed(fake_api):
    with pytest.raises(HermesApiError) as e:
        bridge.HERMES_API.stream_chat("nope", "hi", lambda c: None)
    assert e.value.started is False and e.value.status == 404


def test_error_mid_run_is_marked_as_started(fake_api):
    fake_api.stream = [sse("assistant.delta", {"delta": "par"}), sse("error", {"message": "boom"}),
                       sse("done", {})]
    got = []
    with pytest.raises(HermesApiError) as e:
        bridge.HERMES_API.stream_chat("s1", "hi", got.append)
    assert e.value.started is True
    assert got[-1]["delta"] == "⚠ boom\n"


def test_stream_cut_off_without_done_is_an_error(fake_api):
    fake_api.stream = [sse("assistant.delta", {"delta": "par"})]
    with pytest.raises(HermesApiError) as e:
        bridge.HERMES_API.stream_chat("s1", "hi", lambda c: None)
    assert e.value.started is True


# -- the bridge's routing ------------------------------------------------------
def test_default_profile_turn_goes_through_the_api_server(fake_api, broadcasts, cli_calls):
    got, done = broadcasts
    bridge._spawn_hermes("s1", "hi")
    assert done.wait(5)
    assert cli_calls == []
    assert [p.get("delta") for _, p in got if p["event"] == "chunk"] == [
        "pondering", "┊ terminal ls -la\n", "Hel", "lo"]
    assert got[-1] == ("s1", {"event": "done"})


def test_other_profiles_still_use_the_cli(fake_api, broadcasts, cli_calls):
    _, done = broadcasts
    bridge._spawn_hermes("s1", "hi", profile="dev-hermes-mobile")
    assert done.wait(5)
    assert cli_calls == [("s1", "hi", None, "dev-hermes-mobile")]
    assert not any(r[1].startswith("/api/sessions") for r in fake_api.requests)


def test_image_turns_still_use_the_cli(fake_api, broadcasts, cli_calls, tmp_path):
    _, done = broadcasts
    img = tmp_path / "a.png"
    img.write_bytes(b"x")
    bridge._spawn_hermes("s1", "look", [{"path": str(img), "kind": "image"}])
    assert done.wait(5)
    assert cli_calls == [("s1", "look", str(img), None)]


def test_api_server_down_falls_back_to_the_cli(tmp_path, monkeypatch, broadcasts, cli_calls):
    # a port nothing listens on
    monkeypatch.setattr(bridge, "HERMES_API", HermesApi(tmp_path, url="http://127.0.0.1:9", key=KEY))
    _, done = broadcasts
    bridge._spawn_hermes("s1", "hi")
    assert done.wait(5)
    assert cli_calls == [("s1", "hi", None, None)]


def test_rejected_turn_falls_back_to_the_cli(fake_api, broadcasts, cli_calls):
    _, done = broadcasts
    bridge._spawn_hermes("unknown-to-api", "hi")
    assert done.wait(5)
    assert cli_calls == [("unknown-to-api", "hi", None, None)]


def test_failure_after_partial_reply_is_not_run_twice(fake_api, broadcasts, cli_calls):
    fake_api.stream = [sse("assistant.delta", {"delta": "par"}), sse("error", {"message": "boom"}),
                       sse("done", {})]
    got, done = broadcasts
    bridge._spawn_hermes("s1", "hi")
    assert done.wait(5)
    assert cli_calls == []  # the CLI would answer a second time
    assert any("boom" in (p.get("delta") or "") for _, p in got)
    assert [p["event"] for _, p in got].count("done") == 1


# -- new chats and listing -----------------------------------------------------
def _make_state_db(path):
    con = sqlite3.connect(path)
    con.executescript(
        """CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, title TEXT,
               display_name TEXT, started_at REAL, last_activity_at REAL,
               last_activity_description TEXT, message_count INTEGER DEFAULT 0,
               tool_call_count INTEGER DEFAULT 0, pinned INTEGER DEFAULT 0,
               archived INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0);"""
    )
    return con


def test_chat_start_uses_the_api_server(client, fake_api, tmp_path):
    con = _make_state_db(bridge.STATE_DB)
    con.execute("INSERT INTO sessions (id, source, title, started_at) VALUES ('api_new','api_server','Greeting',?)",
                (time.time(),))
    con.commit()
    con.close()
    r = client.post("/api/v1/chat/start", json={"text": "hello"}, headers=auth())
    assert r.status_code == 200, r.text
    assert r.json()["id"] == "api_new"
    assert r.json()["title"] == "Greeting"
    paths = [p for _, p, _ in fake_api.requests]
    assert "/api/sessions" in paths and "/api/sessions/api_new/chat" in paths


def test_chat_start_for_another_profile_does_not_touch_the_api(client, fake_api):
    r = client.post("/api/v1/chat/start", json={"text": "hello", "profile": "dev-x"}, headers=auth())
    # HERMES_BIN is /bin/false in tests, so the CLI path reports no session id
    assert r.status_code == 502
    assert not any(p.startswith("/api/sessions") for _, p, _ in fake_api.requests)


def test_api_server_sessions_are_listed_under_the_default_bot(client):
    con = _make_state_db(bridge.STATE_DB)
    now = time.time()
    con.executemany(
        "INSERT INTO sessions (id, source, title, started_at, last_activity_at) VALUES (?,?,?,?,?)",
        [("a", "api_server", "via api", now, now), ("b", "telegram", "via tg", now, now - 1)],
    )
    con.commit()
    con.close()
    rows = {s["id"]: s for s in client.get("/api/v1/sessions", headers=auth()).json()}
    assert rows["a"]["profileId"] == "hermes"
    assert rows["b"]["profileId"] == "telegram"


def test_status_reports_which_transport_is_live(client, fake_api):
    _make_state_db(bridge.STATE_DB).close()
    assert client.get("/api/v1/status", headers=auth()).json()["hermesApi"] is True


def test_malformed_response_falls_back_instead_of_hanging(tmp_path, monkeypatch, broadcasts, cli_calls):
    """http.client raises HTTPException (not OSError) for a garbage status line;
    it must still end in a fallback, never a relay thread that dies silently."""
    import socket

    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen()

    def garbage():
        while True:
            try:
                c, _ = srv.accept()
            except OSError:
                return
            c.recv(65536)
            c.sendall(b"NOT-HTTP\r\n\r\n")
            c.close()

    threading.Thread(target=garbage, daemon=True).start()
    api = HermesApi(tmp_path, url=f"http://127.0.0.1:{srv.getsockname()[1]}", key=KEY)
    api._health = (time.monotonic(), True)  # skip the health probe; the turn itself hits garbage
    monkeypatch.setattr(bridge, "HERMES_API", api)
    _, done = broadcasts
    try:
        bridge._spawn_hermes("s1", "hi")
        assert done.wait(5)
    finally:
        srv.close()
    assert cli_calls == [("s1", "hi", None, None)]
