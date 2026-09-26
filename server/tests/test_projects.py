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
def test_the_bridge_never_acts_for_hermes():
    """Hermes orchestrates; the bridge relays. If one of these appears in bridge.py,
    orchestration has leaked out of Hermes (docs/PLAN-projects-orchestrator.md §2)."""
    src = Path(bridge.__file__).read_text()
    for forbidden in (r"issue['\"]?,\s*['\"]create", r"gh issue create", r"kanban['\"]?,\s*['\"]create",
                      r"pr['\"]?,\s*['\"]create", r"os\.kill\(", r"\.send_signal\("):
        assert not re.search(forbidden, src), forbidden
