"""Behavioural tests for the routes the app called but the bridge never had.

The app shipped an Add-memory button, a Cron create/edit/delete flow and a
Servers add/remove flow; all of them hit 404/405, were reported to the UI as a
bare `Exception`, and were swallowed by `catch (_) {}` — so nothing happened and
nothing said so. These tests pin the implemented behaviour.
"""
import json
import subprocess

import pytest

from conftest import auth

import bridge


# ---------------------------------------------------------------- memory ----
def test_memory_add_then_list(client):
    res = client.post("/api/v1/memory", json={"category": "user", "content": "likes espresso"},
                      headers=auth())
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["id"] == "user-0"
    assert body["category"] == "user"

    entries = client.get("/api/v1/memory", headers=auth()).json()
    assert [e["content"] for e in entries] == ["likes espresso"]
    assert entries[0]["id"] == "user-0"


def test_memory_add_appends_and_delete_removes(client):
    for text in ("first", "second", "third"):
        assert client.post("/api/v1/memory", json={"category": "memory", "content": text},
                           headers=auth()).status_code == 200
    assert [e["content"] for e in client.get("/api/v1/memory", headers=auth()).json()] == \
        ["first", "second", "third"]

    assert client.delete("/api/v1/memory/memory-1", headers=auth()).status_code == 200
    assert [e["content"] for e in client.get("/api/v1/memory", headers=auth()).json()] == \
        ["first", "third"]


def test_memory_rejects_empty_and_unknown_category(client):
    assert client.post("/api/v1/memory", json={"category": "user", "content": "  "},
                       headers=auth()).status_code == 400
    assert client.post("/api/v1/memory", json={"category": "root", "content": "x"},
                       headers=auth()).status_code == 400


def test_memory_delete_validates_id(client):
    assert client.delete("/api/v1/memory/../../etc/passwd", headers=auth()).status_code in (400, 404)
    assert client.delete("/api/v1/memory/user-9", headers=auth()).status_code == 404


def test_memory_write_is_atomic(client, tmp_path):
    """A half-written file must never replace live memory (tmp + rename)."""
    client.post("/api/v1/memory", json={"category": "user", "content": "one"}, headers=auth())
    files = list((tmp_path / "memories").iterdir())
    assert [f.name for f in files] == ["USER.md"]


# ------------------------------------------------------------------ cron ----
def test_parse_cron_id():
    assert bridge.parse_cron_id("Created job 16097d11bd81 (daily)") == "16097d11bd81"
    assert bridge.parse_cron_id("job created, see output above") is None
    assert bridge.parse_cron_id("") is None
    # A known id wins over any other hex-looking token in the output.
    assert bridge.parse_cron_id("wrote 12345678 then 16097d11bd81",
                                known_ids={"16097d11bd81"}) == "16097d11bd81"


def test_cron_create_requires_schedule_and_prompt(client):
    assert client.post("/api/v1/cron", json={"prompt": "x"}, headers=auth()).status_code == 400
    assert client.post("/api/v1/cron", json={"schedule": "1h"}, headers=auth()).status_code == 400


def test_cron_create_surfaces_cli_failure(client, monkeypatch):
    """HERMES_BIN is /bin/false in tests: a failing CLI is a 502 with its text,
    never a silent success."""
    res = client.post("/api/v1/cron",
                      json={"schedule": "every 1h", "prompt": "say hi"},
                      headers=auth())
    assert res.status_code == 502
    assert "hermes cron failed" in res.json()["detail"]


def test_cron_update_and_delete_404_on_unknown_job(client):
    assert client.post("/api/v1/cron/nope", json={"name": "x"}, headers=auth()).status_code == 404
    assert client.delete("/api/v1/cron/nope", headers=auth()).status_code == 404


def test_cron_update_requires_something_to_change(client, monkeypatch, tmp_path):
    cron_file = tmp_path / "cron" / "jobs.json"
    cron_file.parent.mkdir(parents=True, exist_ok=True)
    cron_file.write_text(json.dumps({"jobs": [{"id": "abc123456789", "name": "n"}]}))
    assert client.post("/api/v1/cron/abc123456789", json={}, headers=auth()).status_code == 400


def test_cron_delete_calls_the_cli(client, monkeypatch, tmp_path):
    cron_file = tmp_path / "cron" / "jobs.json"
    cron_file.parent.mkdir(parents=True, exist_ok=True)
    cron_file.write_text(json.dumps({"jobs": [{"id": "abc123456789", "name": "n"}]}))
    seen = {}

    def fake_cli(args, timeout=60):
        seen["args"] = args
        return subprocess.CompletedProcess(args, 0, "removed", "")

    monkeypatch.setattr(bridge, "_hermes_cli", fake_cli)
    assert client.delete("/api/v1/cron/abc123456789", headers=auth()).status_code == 200
    assert seen["args"] == ["cron", "remove", "abc123456789"]


# --------------------------------------------------------------- servers ----
def test_servers_crud(client):
    builtin = client.get("/api/v1/servers", headers=auth()).json()
    assert [s["id"] for s in builtin] == ["srv-hermes"]

    created = client.post("/api/v1/servers",
                          json={"id": "srv-1", "name": "Cabin", "baseUrl": "http://10.0.0.5:9130/"},
                          headers=auth())
    assert created.status_code == 200, created.text
    assert created.json()["baseUrl"] == "http://10.0.0.5:9130"  # trailing slash normalised

    ids = [s["id"] for s in client.get("/api/v1/servers", headers=auth()).json()]
    assert ids == ["srv-hermes", "srv-1"]

    updated = client.patch("/api/v1/servers/srv-1", json={"name": "Cabin 2"}, headers=auth())
    assert updated.json()["name"] == "Cabin 2"
    assert updated.json()["baseUrl"] == "http://10.0.0.5:9130"

    assert client.delete("/api/v1/servers/srv-1", headers=auth()).status_code == 200
    assert [s["id"] for s in client.get("/api/v1/servers", headers=auth()).json()] == ["srv-hermes"]


def test_servers_validation_and_builtin_protection(client):
    assert client.post("/api/v1/servers", json={"name": "x", "baseUrl": "10.0.0.5"},
                       headers=auth()).status_code == 400
    assert client.post("/api/v1/servers", json={"baseUrl": "http://x"}, headers=auth()).status_code == 400
    assert client.delete("/api/v1/servers/srv-hermes", headers=auth()).status_code == 400
    assert client.delete("/api/v1/servers/ghost", headers=auth()).status_code == 404
    assert client.patch("/api/v1/servers/srv-hermes", json={"name": "x"},
                        headers=auth()).status_code == 400


# ---------------------------------------------------------------- skills ----
def test_skill_toggle_is_honest(client):
    res = client.post("/api/v1/skills/anything/toggle", headers=auth())
    assert res.status_code == 501
    assert "uninstall" in res.json()["detail"]


# ------------------------------------------------------- Sparky error split --
def test_sparky_auth_error_is_not_reported_as_unreachable(client, monkeypatch):
    import urllib.error

    def boom(*_a, **_k):
        raise urllib.error.HTTPError("u", 401, "Unauthorized", None, None)

    monkeypatch.setattr(bridge, "_fetch_sparky_json", boom)
    monkeypatch.setattr(bridge, "SPARKY_TOKEN", "token")
    res = client.get("/api/v1/coach/budget", headers=auth())
    assert res.status_code == 502
    assert "auth failed" in res.json()["error"]
    assert "unreachable" not in res.json()["error"]


def test_sparky_404_is_reported_as_a_path_problem(client, monkeypatch):
    import urllib.error

    def boom(*_a, **_k):
        raise urllib.error.HTTPError("u", 404, "Not Found", None, None)

    monkeypatch.setattr(bridge, "_fetch_sparky_json", boom)
    monkeypatch.setattr(bridge, "SPARKY_TOKEN", "token")
    res = client.get("/api/v1/coach/budget", headers=auth())
    assert res.status_code == 502
    assert "path wrong" in res.json()["error"]


def test_sparky_dead_host_is_unreachable(client, monkeypatch):
    def boom(*_a, **_k):
        raise OSError("connection refused")

    monkeypatch.setattr(bridge, "_fetch_sparky_json", boom)
    monkeypatch.setattr(bridge, "SPARKY_TOKEN", "token")
    res = client.get("/api/v1/coach/budget", headers=auth())
    assert res.status_code == 503
    assert res.json()["error"] == "sparky unreachable"


@pytest.mark.parametrize("path", ["/api/v1/memory", "/api/v1/cron", "/api/v1/servers"])
def test_new_routes_are_also_protected_by_the_token(client, path):
    assert client.get(path).status_code == 401
