"""Project notes: yours, inert, and the one deliberate difference from Memory.

Memory is injected into the agent's prompt every turn (a token cost forever, and
it can steer the agent). A note must never be: it lives beside the registry and
only reaches a model when the user taps "Ask the agent". These tests pin that
difference as behaviour, not documentation.
"""
import json

import pytest

import bridge
from conftest import auth


@pytest.fixture
def mercury(tmp_path, monkeypatch):
    d = tmp_path / "mercury"
    (d / "tasks").mkdir(parents=True)
    monkeypatch.setattr(bridge, "MERCURY_DIR", d)
    monkeypatch.setattr(bridge, "NOTES_DIR", d / "notes")
    monkeypatch.setattr(bridge, "HERMES", tmp_path)
    project = {"id": "lumen-launcher", "name": "lumen-launcher", "repo": "Flexingg/lumen-launcher",
               "profile": "dev-lumen-launcher", "board": "lumen-launcher", "coder": "claude",
               "gates": "./gradlew test", "defaultBranch": "main"}
    (d / "projects.json").write_text(json.dumps({"projects": [project]}))
    return d


def test_notes_start_empty_and_round_trip(client, mercury):
    assert client.get("/api/v1/projects/lumen-launcher/notes", headers=auth()).json() == []

    r = client.post("/api/v1/projects/lumen-launcher/notes",
                    json={"text": "the fasting card rounds to 5 min"}, headers=auth())
    assert r.status_code == 200
    note = r.json()
    assert note["text"] == "the fasting card rounds to 5 min" and note["id"]

    got = client.get("/api/v1/projects/lumen-launcher/notes", headers=auth()).json()
    assert [n["id"] for n in got] == [note["id"]]
    # On disk, beside the registry — not in the agent's memories/.
    on_disk = json.loads((mercury / "notes" / "lumen-launcher.json").read_text())
    assert on_disk["notes"][0]["text"] == note["text"]
    assert not (mercury / "memories").exists()


def test_notes_keep_their_order_and_are_editable(client, mercury):
    first = client.post("/api/v1/projects/lumen-launcher/notes", json={"text": "one"},
                        headers=auth()).json()
    client.post("/api/v1/projects/lumen-launcher/notes", json={"text": "two"}, headers=auth())

    edited = client.patch(f"/api/v1/projects/lumen-launcher/notes/{first['id']}",
                          json={"text": "one, revised"}, headers=auth()).json()
    assert edited["text"] == "one, revised" and edited["updatedAt"]

    got = client.get("/api/v1/projects/lumen-launcher/notes", headers=auth()).json()
    assert [n["text"] for n in got] == ["one, revised", "two"]


def test_a_note_can_be_deleted(client, mercury):
    note = client.post("/api/v1/projects/lumen-launcher/notes", json={"text": "scratch"},
                       headers=auth()).json()
    assert client.delete(f"/api/v1/projects/lumen-launcher/notes/{note['id']}",
                         headers=auth()).json() == {"ok": True}
    assert client.get("/api/v1/projects/lumen-launcher/notes", headers=auth()).json() == []
    # Deleting twice is a 404, not a silent success.
    assert client.delete(f"/api/v1/projects/lumen-launcher/notes/{note['id']}",
                         headers=auth()).status_code == 404


def test_empty_and_oversized_notes_are_refused(client, mercury):
    assert client.post("/api/v1/projects/lumen-launcher/notes", json={"text": "   "},
                       headers=auth()).status_code == 400
    assert client.post("/api/v1/projects/lumen-launcher/notes", json={"text": "x" * 8001},
                       headers=auth()).status_code == 400


def test_notes_for_an_unlinked_project_are_a_404(client, mercury):
    assert client.get("/api/v1/projects/nope/notes", headers=auth()).status_code == 404
    assert client.post("/api/v1/projects/nope/notes", json={"text": "x"},
                       headers=auth()).status_code == 404


def test_a_note_is_never_written_into_the_agents_memory(client, mercury, tmp_path, monkeypatch):
    """The whole point: notes must not become prompt every turn."""
    mem = tmp_path / "profiles" / "dev-lumen-launcher" / "memories"
    monkeypatch.setattr(bridge, "PROFILES_DIR", tmp_path / "profiles")
    client.post("/api/v1/projects/lumen-launcher/notes", json={"text": "remember me"},
                headers=auth())
    assert not mem.exists()
