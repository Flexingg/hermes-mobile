"""Mercury project views, intents, Plan mode and the notify inbox."""
import json
import re
import sqlite3
import time
from pathlib import Path

import pytest

import bridge
from conftest import auth
from hermes_api import HermesApi
from test_hermes_api import KEY, FakeApi, _make_full_db, _make_state_db  # noqa: F401 (fixtures)


@pytest.fixture
def mercury(tmp_path, monkeypatch):
    d = tmp_path / "mercury"
    (d / "tasks").mkdir(parents=True)
    monkeypatch.setattr(bridge, "MERCURY_DIR", d)
    monkeypatch.setattr(bridge, "MERCURY_BIN", d / "bin")
    monkeypatch.setattr(bridge, "HERMES", tmp_path)
    monkeypatch.setattr(bridge, "_EVENTS", [])
    project = {"id": "lumen-launcher", "name": "lumen-launcher", "repo": "Flexingg/lumen-launcher",
               "profile": "dev-lumen-launcher", "board": "lumen-launcher", "coder": "claude",
               "gates": "./gradlew test", "defaultBranch": "main"}
    (d / "projects.json").write_text(json.dumps({"projects": [project]}))
    return d


def _board(tmp_path, rows):
    db = tmp_path / "kanban" / "boards" / "lumen-launcher" / "kanban.db"
    db.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(db)
    con.execute("""CREATE TABLE tasks (id TEXT, title TEXT, status TEXT, created_at REAL, started_at REAL,
                   completed_at REAL, branch_name TEXT, idempotency_key TEXT, last_failure_error TEXT)""")
    now = time.time()
    for i, (tid, status) in enumerate(rows):
        con.execute("INSERT INTO tasks VALUES (?,?,?,?,?,?,?,?,?)",
                    (tid, f"#{i} task", status, now - i, None, None, f"lumen-launcher/{tid}-x",
                     f"Flexingg/lumen-launcher#{i}", None))
    con.commit()


def _state(mercury, tid, **kw):
    (mercury / "tasks" / f"{tid}.json").write_text(json.dumps({"task": tid, **kw}))


# -- phases and the project view ---------------------------------------------------
@pytest.mark.parametrize("status,state,expected", [
    ("ready", {}, "queued"), ("running", {"phase": "ready"}, "working"), ("blocked", {}, "needs_you"),
    ("review", {"phase": "review"}, "review"), ("review", {"phase": "ready"}, "ready"),
    ("review", {"phase": "ci_retry"}, "ci_retry"), ("done", {"phase": "merged"}, "merged"),
    ("archived", {}, "cancelled"), ("done", {}, "done"),
])
def test_task_phase(status, state, expected):
    assert bridge._task_phase(status, state) == expected


def test_project_view_and_tasks(client, mercury, tmp_path):
    _board(tmp_path, [("t_a", "review"), ("t_b", "running"), ("t_c", "ready")])
    _state(mercury, "t_a", phase="ready", prNumber=12, prUrl="https://x/pull/12", ci="green",
           apk=str(mercury / "apks" / "a.apk"), issue=0)
    [p] = client.get("/api/v1/projects", headers=auth()).json()
    assert p["status"] == "ready" and p["counts"] == {"needs_you": 0, "ready": 1, "working": 1, "queued": 1}
    assert p["awake"] is True and p["coder"] == "claude"
    detail = client.get("/api/v1/projects/lumen-launcher", headers=auth()).json()
    a = next(t for t in detail["tasks"] if t["id"] == "t_a")
    assert (a["phase"], a["prNumber"], a["ci"]) == ("ready", 12, "green")
    assert client.get("/api/v1/projects/nope", headers=auth()).status_code == 404


def test_needs_you_outranks_everything(client, mercury, tmp_path):
    _board(tmp_path, [("t_a", "review"), ("t_b", "blocked")])
    _state(mercury, "t_a", phase="ready")
    assert client.get("/api/v1/projects", headers=auth()).json()[0]["status"] == "needs_you"


def test_no_projects_is_an_empty_list(client, mercury):
    (mercury / "projects.json").unlink()
    assert client.get("/api/v1/projects", headers=auth()).json() == []


def test_project_sessions_come_from_its_profile(client, mercury, tmp_path, monkeypatch):
    monkeypatch.setattr(bridge, "PROFILES_DIR", tmp_path / "profiles")
    db = tmp_path / "profiles" / "dev-lumen-launcher" / "state.db"
    db.parent.mkdir(parents=True)
    con = _make_state_db(db)
    con.execute("INSERT INTO sessions (id, source, title, last_activity_at) VALUES ('p1','cli','plan',1)")
    con.commit()
    rows = client.get("/api/v1/projects/lumen-launcher/sessions", headers=auth()).json()
    assert [(r["id"], r["profileId"]) for r in rows] == [("p1", "dev-lumen-launcher")]


def test_project_memory_is_the_profiles_own(client, tmp_path, monkeypatch):
    monkeypatch.setattr(bridge, "PROFILES_DIR", tmp_path / "profiles")
    mem = tmp_path / "profiles" / "dev-lumen-launcher" / "memories"
    mem.mkdir(parents=True)
    (mem / "MEMORY.md").write_text("gradle needs --no-daemon")
    got = client.get("/api/v1/memory?profile=dev-lumen-launcher", headers=auth()).json()
    assert [m["content"] for m in got] == ["gradle needs --no-daemon"]
    r = client.post("/api/v1/memory", json={"category": "memory", "content": "more", "profile": "dev-lumen-launcher"},
                    headers=auth())
    assert r.status_code == 200 and "more" in (mem / "MEMORY.md").read_text()
    assert client.get("/api/v1/memory?profile=../../x", headers=auth()).status_code == 400


# -- the notify inbox ------------------------------------------------------------------
@pytest.fixture
def notify_ok(mercury, monkeypatch):
    (mercury / "notify.key").write_text("nk-123\n")
    monkeypatch.setattr(bridge, "_LOOPBACK", {"testclient"})
    pushes = []
    monkeypatch.setattr(bridge, "_send_push", lambda t, b, d=None: pushes.append((t, b, d)) or 1)
    return pushes


def test_notify_pushes_ready_and_records_the_event(client, notify_ok):
    body = {"kind": "ready", "project": "lumen-launcher", "task": "t_a", "title": "lumen #3 ready",
            "body": "Fasting card", "url": "https://x/pull/12", "apk": "/h/.hermes/mercury/apks/a.apk"}
    r = client.post("/internal/notify", json=body, headers={"X-Mercury-Notify-Key": "nk-123"})
    assert r.status_code == 200 and r.json()["pushed"] == 1
    title, text, data = notify_ok[0]
    assert (title, data["kind"], data["apk"]) == ("lumen #3 ready", "ready", body["apk"])
    [ev] = client.get("/api/v1/events", headers=auth()).json()
    assert ev["kind"] == "ready" and ev["url"] == body["url"]


def test_working_events_are_not_pushed(client, notify_ok):
    r = client.post("/internal/notify", json={"kind": "working", "project": "p", "title": "t"},
                    headers={"X-Mercury-Notify-Key": "nk-123"})
    assert r.status_code == 200 and notify_ok == []


def test_notify_needs_the_key_and_loopback(client, mercury, monkeypatch):
    (mercury / "notify.key").write_text("nk-123")
    body = {"kind": "info", "project": "p", "title": "t"}
    # the test client is not loopback
    assert client.post("/internal/notify", json=body, headers={"X-Mercury-Notify-Key": "nk-123"}).status_code == 403
    monkeypatch.setattr(bridge, "_LOOPBACK", {"testclient"})
    assert client.post("/internal/notify", json=body, headers={"X-Mercury-Notify-Key": "wrong"}).status_code == 403
    # the app's bearer token is not a notify key
    assert client.post("/internal/notify", json=body, headers=auth()).status_code == 403
    (mercury / "notify.key").unlink()
    assert client.post("/internal/notify", json=body, headers={"X-Mercury-Notify-Key": ""}).status_code == 403


# -- intents and Plan mode ----------------------------------------------------------------
@pytest.fixture
def api(tmp_path, monkeypatch, mercury):
    fake = FakeApi().start()
    fake.sessions |= {"api_new", "orch", "plan1"}
    fake.profile_keys["dev-lumen-launcher"] = "D" * 32
    home = tmp_path / "profiles" / "dev-lumen-launcher"
    home.mkdir(parents=True, exist_ok=True)
    (home / ".env").write_text("API_SERVER_KEY=" + "D" * 32 + "\n")
    monkeypatch.setattr(bridge, "HERMES_API", HermesApi(tmp_path, url=fake.url, key=KEY, multiplex=lambda: True))
    monkeypatch.setattr(bridge, "PROFILES_DIR", tmp_path / "profiles")
    _make_state_db(bridge.STATE_DB).close()
    yield fake
    fake.stop()


def test_intents_go_to_the_orchestrator_chat(client, api, mercury):
    r = client.post("/api/v1/hermes/intent", json={"kind": "link_repo", "payload": {"repo": "Flexingg/x",
                                                                                    "coder": "agy"}}, headers=auth())
    assert r.status_code == 200, r.text
    assert r.json()["reply"] == "PONG"
    create, chat = api.requests[-2], api.requests[-1]
    assert create[1] == "/api/sessions"  # the orchestrator chat is created once
    assert chat[1] == "/api/sessions/api_new/chat"
    assert chat[2]["message"] == '[Mercury: link repo] {"repo": "Flexingg/x", "coder": "agy"}'
    assert json.loads((mercury / "orchestrator.json").read_text())["sessionId"] == "api_new"


def test_unknown_intents_are_refused(client, api):
    assert client.post("/api/v1/hermes/intent", json={"kind": "rm_rf"}, headers=auth()).status_code == 400


def test_edit_task_goes_to_the_orchestrator_with_the_note(client, api):
    """A suggestion about a task is the orchestrator's call: it owns the board."""
    r = client.post("/api/v1/hermes/intent", json={
        "kind": "edit_task", "project": "lumen-launcher",
        "payload": {"task": "t_abc", "note": "keep the header pinned", "phase": "review",
                    "issue": 42, "pr": 9}}, headers=auth())
    assert r.status_code == 200, r.text
    path, body = api.requests[-1][1], api.requests[-1][2]
    assert path == "/api/sessions/" + bridge._orchestrator_session() + "/chat"
    assert body["message"].startswith('[Mercury: edit task] {"project": "lumen-launcher"')
    assert '"note": "keep the header pinned"' in body["message"]
    assert '"pr": 9' in body["message"]


def test_followup_issue_goes_to_the_project_agent(client, api, tmp_path, monkeypatch):
    """New work after a merge belongs to the project agent, which owns the repo."""
    monkeypatch.setattr(bridge, "PROFILES_DIR", tmp_path / "profiles")
    db = tmp_path / "profiles" / "dev-lumen-launcher" / "state.db"
    db.parent.mkdir(parents=True, exist_ok=True)
    con = _make_full_db(db)
    con.execute("INSERT INTO sessions (id, source, title) VALUES ('plan1','api_server','plan')")
    con.commit()
    con.close()
    r = client.post("/api/v1/hermes/intent", json={
        "kind": "followup_issue", "project": "lumen-launcher", "sessionId": "plan1",
        "payload": {"task": "t_abc", "note": "the card should keep the streak", "issue": 42, "pr": 9}},
        headers=auth())
    assert r.status_code == 200, r.text
    path, body = api.requests[-1][1], api.requests[-1][2]
    assert path == "/p/dev-lumen-launcher/api/sessions/plan1/chat"
    assert body["message"].startswith("[Mercury: follow-up issue] ")
    assert '"repo": "Flexingg/lumen-launcher"' in body["message"]
    assert "keep the streak" in body["message"]


def test_followup_without_a_session_opens_one(client, api):
    """No sessionId: the project's newest chat is used, or one is started."""
    r = client.post("/api/v1/hermes/intent", json={
        "kind": "followup_issue", "project": "lumen-launcher",
        "payload": {"task": "t_abc", "note": "smaller heading"}}, headers=auth())
    assert r.status_code == 200, r.text
    assert api.requests[-1][1].startswith("/p/dev-lumen-launcher/api/sessions/")


# -- the tunnel the server runs, as the app sees it ---------------------------------
def test_tunnel_is_reported_when_the_state_file_names_a_live_cloudflared(client, mercury, monkeypatch):
    """Liveness is a /proc read: the bridge must not signal processes itself."""
    monkeypatch.setattr(Path, "read_bytes", lambda self: b"/home/x/.local/bin/cloudflared\x00tunnel\x00--url\x00")
    (mercury / "tunnel.json").write_text(json.dumps(
        {"kind": "quick", "url": "https://abc-def.trycloudflare.com", "pid": 4242,
         "port": 9130, "startedAt": time.time(), "accessProtected": False}))
    d = client.get("/api/v1/tunnel", headers=auth()).json()
    assert d["up"] is True and d["url"] == "https://abc-def.trycloudflare.com"
    assert d["kind"] == "quick" and d["port"] == 9130
    assert "[Mercury: tunnel]" in d["how"]


def test_no_tunnel_stale_pid_or_wrong_process_reads_as_down(client, mercury):
    assert client.get("/api/v1/tunnel", headers=auth()).json()["up"] is False
    (mercury / "tunnel.json").write_text(json.dumps({"url": "https://old.trycloudflare.com", "pid": 999999}))
    d = client.get("/api/v1/tunnel", headers=auth()).json()
    # A dead pid, or a pid that is not cloudflared, must not be advertised as a
    # working tunnel: the app would send the user to a URL that goes nowhere.
    assert d["up"] is False and d["url"] is None


def test_tunnel_endpoint_needs_the_token(client):
    assert client.get("/api/v1/tunnel").status_code == 401


def test_file_issue_goes_to_the_projects_plan_chat(client, api):
    draft = {"title": "Add fasting card", "body": "b", "acceptance": ["x"]}
    r = client.post("/api/v1/hermes/intent", json={"kind": "file_issue", "project": "lumen-launcher",
                                                   "sessionId": "plan1", "payload": {"draft": draft}},
                    headers=auth())
    assert r.status_code == 200, r.text
    path, body = api.requests[-1][1], api.requests[-1][2]
    assert path == "/p/dev-lumen-launcher/api/sessions/plan1/chat"
    assert "[Mercury: file issue]" in body["message"] and json.dumps(draft) in body["message"]


def test_plan_mode_turn_carries_the_plan_rules(client, api, monkeypatch):
    spawned = []
    monkeypatch.setattr(bridge, "_spawn_hermes", lambda sid, text, att, profile=None, system=None:
                        spawned.append((sid, text, profile, system)))
    r = client.post("/api/v1/sessions/plan1/messages", headers=auth(),
                    json={"text": "add a fasting card", "mode": "plan", "project": "lumen-launcher",
                          "profile": "dev-lumen-launcher"})
    assert r.status_code == 200, r.text
    sid, text, profile, system = spawned[0]
    assert text.startswith("[Mercury Plan · project lumen-launcher · Flexingg/lumen-launcher]\n")
    assert "issue-planner" in system and "READ-ONLY" in system
    r = client.post("/api/v1/sessions/plan1/messages", headers=auth(), json={"text": "x", "mode": "plan",
                                                                             "profile": "nobody"})
    assert r.status_code == 400


def test_intents_need_the_api_server(client, mercury, monkeypatch):
    monkeypatch.setattr(bridge, "HERMES_API", HermesApi(Path("/nonexistent"), key=""))
    r = client.post("/api/v1/hermes/intent", json={"kind": "pause"}, headers=auth())
    assert r.status_code == 503


# -- the rule that keeps the bridge thin -------------------------------------------------
def _function_source(src: str, name: str) -> tuple[int, int]:
    """Byte range of one top-level function's source."""
    start = src.index(f"def {name}(")
    nxt = src.find("\ndef ", start + 1)
    return start, len(src) if nxt == -1 else nxt


def test_the_bridge_never_acts_for_hermes():
    """Hermes orchestrates; the bridge relays. If one of these appears in bridge.py,
    orchestration has leaked out of Hermes (docs/PLAN-projects-orchestrator.md §2)."""
    src = Path(bridge.__file__).read_text()
    for forbidden in (r"issue['\"]?,\s*['\"]create", r"gh issue create", r"kanban['\"]?,\s*['\"]create",
                      r"pr['\"]?,\s*['\"]create", r"os\.kill\("):
        assert not re.search(forbidden, src), forbidden
    # Stop is the one deliberate exception, and it stays narrow: the bridge may
    # signal only the turn process IT started (a Popen handle it recorded in
    # ACTIVE_RUNS), never a process it found by scanning pids or names. That is
    # the line Mercury's never-touch list draws — the bridge must never be able
    # to reach an agent, gateway or coder run it does not own.
    start, end = _function_source(src, "_request_stop")
    assert "proc.send_signal(" in src[start:end]
    for m in re.finditer(r"\.send_signal\(", src):
        assert start <= m.start() < end, "send_signal() outside _request_stop"
    assert "psutil" not in src[start:end] and "os.kill" not in src[start:end]


def test_project_chats_are_read_from_the_project_agents_db(client, mercury, tmp_path, monkeypatch):
    """A Plan chat lives in dev-<repo>/state.db: opening it must read that db."""
    monkeypatch.setattr(bridge, "PROFILES_DIR", tmp_path / "profiles")
    _make_full_db(bridge.STATE_DB).close()
    db = tmp_path / "profiles" / "dev-lumen-launcher" / "state.db"
    db.parent.mkdir(parents=True)
    con = _make_full_db(db)
    con.execute("INSERT INTO sessions (id, source, title) VALUES ('plan9','api_server','plan')")
    con.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES ('plan9','user','fasting card',1)")
    con.commit()
    msgs = client.get("/api/v1/sessions/plan9/messages", headers=auth()).json()
    assert [m["text"] for m in msgs] == ["fasting card"]
    assert bridge._session_owner("plan9") == "dev-lumen-launcher"
