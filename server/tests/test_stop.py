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
