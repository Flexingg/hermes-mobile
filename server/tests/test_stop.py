"""Stop: the graceful steer, the confirmed hard kill, and the CLI fallback.

The app's Stop is two-stage (decided 2026-09-26): the first tap asks the turn to
finish the step it is on and end, the second confirms and cuts it off where it
is. Both halves are exercised here against the same fake API server the rest of
the bridge tests use, including the awkward parts — the run id only exists after
the gateway's first SSE event, and a stop can arrive after the reply finished.
"""
import threading
import time

import pytest

import bridge
from conftest import auth
from hermes_api import STOP_STEER_NOTE
from test_hermes_api import FakeApi, broadcasts, fake_api  # noqa: F401 (fixtures)


@pytest.fixture(autouse=True)
def _no_runs_leak_between_tests(monkeypatch):
    monkeypatch.setattr(bridge, "ACTIVE_RUNS", {})


def _wait_for_run(session_id: str, timeout: float = 5.0) -> dict:
    """The bridge learns the run id from the first SSE event; wait for it."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        info = bridge._active_run(session_id) or {}
        if info.get("run_id"):
            return info
        time.sleep(0.02)
    raise AssertionError(f"no run id recorded for {session_id}")


# -- the live API-server turn ---------------------------------------------------
def test_stop_graceful_steers_the_run_instead_of_tearing_it_down(client, fake_api, broadcasts):
    fake_api.pause = threading.Event()
    bridge._spawn_hermes("s1", "hi")
    assert _wait_for_run("s1")["run_id"] == "r-1"

    r = client.post("/api/v1/sessions/s1/stop", json={"mode": "graceful"}, headers=auth())
    assert r.status_code == 200
    assert r.json() == {"ok": True, "mode": "graceful", "applied": "graceful"}
    assert fake_api.steers == [("r-1", STOP_STEER_NOTE)]
    assert fake_api.stops == []  # nothing was interrupted

    fake_api.pause.set()
    _, done = broadcasts
    assert done.wait(5)
    assert bridge._active_run("s1") is None  # the turn is over: nothing left to stop


def test_stop_hard_interrupts_the_run(client, fake_api, broadcasts):
    fake_api.pause = threading.Event()
    bridge._spawn_hermes("s1", "hi")
    _wait_for_run("s1")

    r = client.post("/api/v1/sessions/s1/stop", json={"mode": "hard"}, headers=auth())
    assert r.json() == {"ok": True, "mode": "hard", "applied": "hard"}
    assert fake_api.stops == ["r-1"]
    assert fake_api.steers == []

    fake_api.pause.set()
    _, done = broadcasts
    assert done.wait(5)


def test_graceful_then_hard_is_the_two_tap_sequence(client, fake_api, broadcasts):
    """First tap steers, second tap stops — the order the app sends them in."""
    fake_api.pause = threading.Event()
    bridge._spawn_hermes("s1", "hi")
    _wait_for_run("s1")

    client.post("/api/v1/sessions/s1/stop", json={"mode": "graceful"}, headers=auth())
    client.post("/api/v1/sessions/s1/stop", json={"mode": "hard"}, headers=auth())
    assert fake_api.steers == [("r-1", STOP_STEER_NOTE)]
    assert fake_api.stops == ["r-1"]

    fake_api.pause.set()
    _, done = broadcasts
    assert done.wait(5)


# -- the edges ------------------------------------------------------------------
def test_stop_with_nothing_running_is_not_an_error(client):
    """A tap that races the end of a reply: say so, do not 500."""
    r = client.post("/api/v1/sessions/s1/stop", json={"mode": "graceful"}, headers=auth())
    assert r.status_code == 200
    assert r.json()["applied"] == "none"


def test_stop_rejects_an_unknown_mode(client):
    r = client.post("/api/v1/sessions/s1/stop", json={"mode": "nuke"}, headers=auth())
    assert r.status_code == 400


def test_stop_tells_every_listener_that_it_was_asked(client, fake_api, broadcasts):
    """A second device on the same chat shows the stopped state too."""
    fake_api.pause = threading.Event()
    bridge._spawn_hermes("s1", "hi")
    _wait_for_run("s1")
    client.post("/api/v1/sessions/s1/stop", json={"mode": "graceful"}, headers=auth())
    got, _ = broadcasts
    assert ("s1", {"event": "stop_requested", "mode": "graceful", "applied": "graceful"}) in got
    fake_api.pause.set()


def test_a_run_that_already_finished_stops_nothing(client, fake_api, broadcasts):
    """The run id is stale (the reply came back between the tap and the call)."""
    fake_api.pause = threading.Event()
    bridge._spawn_hermes("s1", "hi")
    _wait_for_run("s1")
    fake_api.runs.clear()  # the gateway no longer knows it
    assert client.post("/api/v1/sessions/s1/stop", json={"mode": "hard"},
                       headers=auth()).json()["applied"] == "none"
    fake_api.pause.set()


# -- the CLI fallback ------------------------------------------------------------
class FakeProc:
    """Stands in for the `hermes chat` subprocess the bridge started."""

    def __init__(self):
        self.signals = []
        self.alive = True

    def poll(self):
        return None if self.alive else 0

    def send_signal(self, sig):
        self.signals.append(sig)
        self.alive = False


@pytest.fixture
def cli_turn(monkeypatch, broadcasts):
    """A turn on the CLI transport, held open so a stop can land mid-turn."""
    proc = FakeProc()
    holding = threading.Event()

    def fake_cli(session_id, query, img_path, prof):
        bridge._set_run_proc(session_id, proc)  # what the real _run_hermes_cli does
        holding.wait(5)

    monkeypatch.setattr(bridge, "_run_hermes_cli", fake_cli)
    yield proc, holding
    holding.set()


@pytest.mark.parametrize("mode,expected", [("graceful", "SIGINT"), ("hard", "SIGKILL")])
def test_stop_signals_the_cli_turn(client, cli_turn, mode, expected):
    import signal as sig

    proc, holding = cli_turn
    bridge._spawn_hermes("s1", "hi", profile="dev-hermes-mobile")  # not served -> CLI
    for _ in range(100):
        if bridge._active_run("s1"):
            break
        time.sleep(0.02)
    r = client.post("/api/v1/sessions/s1/stop", json={"mode": mode}, headers=auth())
    assert r.json()["applied"] == mode
    assert proc.signals == [getattr(sig, expected)]
    holding.set()


# -- group chats -----------------------------------------------------------------
# A group message fans out to every member agent, each its own turn, so the bridge
# records one handle per agent (keyed `<gid>#<agent>`) and a group Stop acts on
# all of them through the same _request_stop the session path uses.
@pytest.fixture
def group_store(monkeypatch):
    """Capture what the group path persists instead of writing the group file."""
    saved = []
    monkeypatch.setattr(bridge, "_append_group_message", lambda gid, msg: saved.append((gid, msg)))
    return saved


def _group_turn(agent: str = "@hermes") -> threading.Thread:
    t = threading.Thread(target=bridge._run_group_agent, args=("g1", agent, "hi"), daemon=True)
    t.start()
    return t


def test_group_stop_graceful_steers_the_agents_run(client, fake_api, broadcasts, group_store):
    fake_api.pause = threading.Event()
    t = _group_turn()
    assert _wait_for_run("g1#@hermes")["run_id"] == "r-1"

    r = client.post("/api/v1/groups/g1/stop", json={"mode": "graceful"}, headers=auth())
    assert r.status_code == 200
    assert r.json() == {"ok": True, "mode": "graceful", "applied": "graceful"}
    assert fake_api.steers == [("r-1", STOP_STEER_NOTE)]
    assert fake_api.stops == []  # nothing was interrupted
    got, _ = broadcasts
    assert ("g1", {"event": "stop_requested", "mode": "graceful", "applied": "graceful"}) in got

    fake_api.pause.set()
    t.join(5)
    assert bridge._active_run("g1#@hermes") is None  # the turn is over: nothing left to stop


def test_group_stop_hard_interrupts_the_agents_run(client, fake_api, broadcasts, group_store):
    fake_api.pause = threading.Event()
    t = _group_turn()
    _wait_for_run("g1#@hermes")

    r = client.post("/api/v1/groups/g1/stop", json={"mode": "hard"}, headers=auth())
    assert r.json() == {"ok": True, "mode": "hard", "applied": "hard"}
    assert fake_api.stops == ["r-1"]
    assert fake_api.steers == []

    fake_api.pause.set()
    t.join(5)


def test_a_group_reply_on_the_api_server_is_persisted(fake_api, broadcasts, group_store):
    """There is no session row to read a group reply back from: the group store
    is the record, so the streamed answer has to land there."""
    bridge._run_group_agent("g1", "@hermes", "hi")
    assert len(group_store) == 1
    gid, msg = group_store[0]
    assert gid == "g1" and msg["agent"] == "@hermes" and msg["role"] == "assistant"
    assert msg["text"] == "Hello"
    got, _ = broadcasts
    chunks = [p for g, p in got if p.get("event") == "chunk"]
    assert chunks and all(p["agent"] == "@hermes" for p in chunks)  # tagged for the bubble
    assert ("g1", {"event": "done", "agent": "@hermes"}) in got


def test_group_stop_with_nothing_running_is_not_an_error(client, broadcasts):
    """An unknown or idle group: nothing to stop, and a Stop never fails mid-turn."""
    r = client.post("/api/v1/groups/nope/stop", json={"mode": "hard"}, headers=auth())
    assert r.status_code == 200
    assert r.json()["applied"] == "none"


def test_group_stop_rejects_an_unknown_mode(client):
    r = client.post("/api/v1/groups/g1/stop", json={"mode": "nuke"}, headers=auth())
    assert r.status_code == 400


def test_group_stop_leaves_other_groups_and_sessions_alone(client, broadcasts):
    """Stopping g1 must not reach g10's agents or a session's turn."""
    procs = {k: FakeProc() for k in ("g1#@a", "g1#@b", "g10#@a", "s1")}
    for key, proc in procs.items():
        bridge._register_run(key, "dev-hermes-mobile")
        bridge._set_run_proc(key, proc)

    r = client.post("/api/v1/groups/g1/stop", json={"mode": "graceful"}, headers=auth())
    assert r.json()["applied"] == "graceful"
    import signal as sig
    assert procs["g1#@a"].signals == [sig.SIGINT]
    assert procs["g1#@b"].signals == [sig.SIGINT]  # every agent in the fan-out
    assert procs["g10#@a"].signals == []
    assert procs["s1"].signals == []


@pytest.mark.parametrize("mode,expected", [("graceful", "SIGINT"), ("hard", "SIGKILL")])
def test_group_stop_signals_the_cli_turn_it_recorded(client, monkeypatch, broadcasts,
                                                     group_store, mode, expected):
    """A profile the API server does not serve runs on the CLI; Stop signals the
    process the bridge started for that agent's turn — and nothing else."""
    import signal as sig

    holding = threading.Event()

    class HeldProc(FakeProc):
        """The `hermes chat -q` process, alive until it is signalled."""
        stdout = None

        def send_signal(self, s):
            super().send_signal(s)
            holding.set()

        def wait(self):
            holding.wait(5)
            return 0

    spawned = []

    def popen(cmd, **kw):
        spawned.append(HeldProc())
        return spawned[-1]

    monkeypatch.setattr(bridge.subprocess, "Popen", popen)
    # A session turn running at the same time: its process is not the group's.
    bystander = FakeProc()
    bridge._register_run("s1", "dev-hermes-mobile")
    bridge._set_run_proc("s1", bystander)

    t = _group_turn("@dev-hermes-mobile")  # not served -> CLI
    for _ in range(100):
        if (bridge._active_run("g1#@dev-hermes-mobile") or {}).get("proc"):
            break
        time.sleep(0.02)

    r = client.post("/api/v1/groups/g1/stop", json={"mode": mode}, headers=auth())
    assert r.json()["applied"] == mode
    assert len(spawned) == 1
    assert spawned[0].signals == [getattr(sig, expected)]
    assert bystander.signals == []
    t.join(5)
    assert bridge._active_run("g1#@dev-hermes-mobile") is None
