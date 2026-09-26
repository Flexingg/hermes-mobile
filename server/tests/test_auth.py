"""Behavioural tests for the bridge's auth surface.

These exist because the shipped bridge served ~/.hermes to any host on the LAN
with no credential at all (GET /html/<abs path>/config.yaml → 200). Each test
here fails if that hole is reopened.
"""
import json
import subprocess
import sys
from pathlib import Path

from conftest import TOKEN, auth

import bridge

REPO_ROOT = Path(__file__).resolve().parents[2]


def test_refuses_to_start_without_token():
    """The process must exit, not quietly serve an unauthenticated bridge."""
    env = {"PATH": "/usr/bin:/bin", "HERMES_HOME": "/tmp/does-not-matter"}
    proc = subprocess.run(
        [sys.executable, "-c", "import bridge"],
        cwd=str(REPO_ROOT / "server"),
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert proc.returncode != 0, "bridge imported without BRIDGE_TOKEN"
    assert "BRIDGE_TOKEN is required" in (proc.stdout + proc.stderr)


def test_refuses_the_unit_template_placeholder():
    """The tracked unit ships BRIDGE_TOKEN=REPLACE_WITH_TOKEN. Accepting that
    placeholder is the same as having no token — the value is public."""
    env = {
        "PATH": "/usr/bin:/bin",
        "HERMES_HOME": "/tmp/does-not-matter",
        "BRIDGE_TOKEN": "REPLACE_WITH_TOKEN",
    }
    proc = subprocess.run(
        [sys.executable, "-c", "import bridge"],
        cwd=str(REPO_ROOT / "server"),
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert proc.returncode != 0
    assert "placeholder or too short" in (proc.stdout + proc.stderr)


def test_refuses_a_short_token():
    env = {
        "PATH": "/usr/bin:/bin",
        "HERMES_HOME": "/tmp/does-not-matter",
        "BRIDGE_TOKEN": "hunter2",
    }
    proc = subprocess.run(
        [sys.executable, "-c", "import bridge"],
        cwd=str(REPO_ROOT / "server"),
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert proc.returncode != 0
    assert "too short" in (proc.stdout + proc.stderr)


def test_api_requires_token(client):
    assert client.get("/api/v1/tools").status_code == 401
    assert client.get("/api/v1/tools", headers={"Authorization": "Bearer wrong"}).status_code == 401
    assert client.get("/api/v1/tools", headers=auth()).status_code == 200


def test_html_preview_requires_token(client):
    """The exact hole: this path used to return 200 with ~/.hermes/config.yaml."""
    secret = REPO_ROOT / "docs" / "REVIEW-2026-09-25.md"
    assert secret.is_file()
    assert client.get("/html" + str(secret)).status_code == 401
    assert client.get("/html" + str(secret), headers=auth()).status_code == 200


def test_html_preview_refuses_non_preview_types(client, tmp_path, monkeypatch):
    """Only preview MIME types are served — a .yaml/.env/.db is a 404 even with
    a valid token, so the route can never become a file downloader again."""
    monkeypatch.setattr(bridge, "_file_roots", lambda: [tmp_path.resolve()])
    for name in ("config.yaml", ".env", "state.db", "id_rsa", "release.jks"):
        f = tmp_path / name
        f.write_text("secrets")
        assert client.get(f"/html{f}", headers=auth()).status_code == 404, name
    ok = tmp_path / "preview.html"
    ok.write_text("<h1>hi</h1>")
    res = client.get(f"/html{ok}", headers=auth())
    assert res.status_code == 200
    assert res.headers["content-type"].startswith("text/html")


def test_html_preview_rejects_paths_outside_roots(client):
    assert client.get("/html/etc/passwd", headers=auth()).status_code == 403


def test_websocket_requires_token(client):
    """An unauthenticated upgrade must be refused *before* accept().

    Run on a thread with a deadline on purpose: if the check is ever removed the
    connection is accepted and the receive blocks forever, which would hang CI
    instead of failing it — a test that cannot fail is how this repo shipped a
    one-assertion suite.
    """
    import threading

    from starlette.websockets import WebSocketDisconnect

    result: dict = {}

    def attempt() -> None:
        try:
            with client.websocket_connect("/ws/chat/anything") as ws:
                ws.receive_text()  # blocks when the app wrongly accepted
            result["outcome"] = "accepted"
        except WebSocketDisconnect as exc:
            result["outcome"] = exc.code
        except Exception as exc:  # noqa: BLE001
            result["outcome"] = f"error:{exc}"

    worker = threading.Thread(target=attempt, daemon=True)
    worker.start()
    worker.join(timeout=5)
    assert not worker.is_alive(), (
        "the bridge accepted an unauthenticated WebSocket — the handshake should "
        "have been refused with close code 1008"
    )
    assert result.get("outcome") == 1008, (
        f"expected policy-violation close (1008), got {result.get('outcome')!r}"
    )


def test_websocket_accepts_valid_token(client):
    with client.websocket_connect(f"/ws/chat/anything?token={TOKEN}"):
        pass  # handshake succeeded; the handler is now waiting on the queue


def test_no_wildcard_cors(client):
    res = client.get("/api/v1/tools", headers={**auth(), "Origin": "https://evil.example"})
    assert "access-control-allow-origin" not in {k.lower() for k in res.headers}


def test_docs_and_openapi_are_not_served(client):
    """FastAPI's /docs, /redoc and /openapi.json are outside /api/v1, so they
    were readable without a token — a free route map including the terminal."""
    for path in ("/docs", "/redoc", "/openapi.json"):
        assert client.get(path).status_code == 404, path
        assert client.get(path, headers=auth()).status_code == 404, path


def test_non_ascii_token_is_rejected_not_a_500(client):
    """`hmac.compare_digest` raises TypeError on a str with non-ASCII characters,
    so a hostile `Authorization: Bearer töken` (sent as latin-1 bytes on the
    wire) used to become a 500 instead of a 401. Tested at the function because
    httpx refuses to encode a non-ASCII header itself; the live check with a raw
    latin-1 header is in the delivery report."""
    assert bridge._token_ok("tökén") is False
    assert bridge._token_ok("tökén".encode("latin-1").decode("latin-1")) is False
    assert bridge._token_ok(None) is False
    assert bridge._token_ok("") is False
    assert bridge._token_ok("plüsch-0123456789abcdef") is False
    assert bridge._token_ok(TOKEN) is True


def test_healthz_does_not_disclose_The_home_path(client):
    body = client.get("/healthz").json()
    assert body == {"ok": True}
    assert "hermes" not in json.dumps(body).lower()


def test_no_duplicate_routes():
    """Two identical handlers for one path/method silently shadow each other
    (coach_sync_health was registered twice)."""
    seen = set()
    dupes = []
    for route in bridge.app.routes:
        path = getattr(route, "path", None)
        methods = tuple(sorted(getattr(route, "methods", None) or ("WS",)))
        if path is None:
            continue
        key = (path, methods)
        if key in seen:
            dupes.append(key)
        seen.add(key)
    assert dupes == []
