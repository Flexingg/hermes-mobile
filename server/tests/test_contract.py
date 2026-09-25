"""Tests for tools/contract_check.py — the drift detector itself must fail.

A check that cannot fail is worse than no check (the repo shipped exactly one
test, which could only fail if a widget stopped rendering text). These pin the
detector: it must catch a phantom client call and must not report false drift
on the real files.
"""
import importlib.util
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("contract_check", REPO / "tools" / "contract_check.py")
contract_check = importlib.util.module_from_spec(_spec)
sys.modules["contract_check"] = contract_check
_spec.loader.exec_module(contract_check)

SERVER_SRC = (REPO / "server" / "bridge.py").read_text()
CLIENT_SRC = (REPO / "lib" / "data" / "hermes_repository.dart").read_text()


def test_real_files_have_no_drift():
    assert contract_check.find_drift(SERVER_SRC, CLIENT_SRC) == []


def test_client_paths_are_normalised_to_templates():
    calls = contract_check.client_calls(CLIENT_SRC)
    assert ("GET", "/api/v1/sessions/{}/messages") in calls
    assert ("DELETE", "/api/v1/cron/{}") in calls
    assert ("WEBSOCKET", "/ws/chat/{}") in calls
    assert ("POST", "/api/v1/chat/start") in calls


def test_detects_a_phantom_client_call():
    server = '@app.get("/api/v1/cron")\ndef cron():\n    return []\n'
    client = """
      Future<void> createCronJob() async => _post('/api/v1/cron');
      Future<List<dynamic>> cronJobs() async => _get('/api/v1/cron');
    """
    drift = contract_check.find_drift(server, client)
    assert drift == ["POST      /api/v1/cron"], drift


def test_detects_a_path_only_reference_that_does_not_exist():
    server = '@app.get("/api/v1/status")\n'
    client = r"final uri = Uri.parse('$baseUrl/api/v1/nope');"
    assert contract_check.find_drift(server, client) == ["(path)    /api/v1/nope"]


def test_detects_a_phantom_websocket():
    assert contract_check.find_drift("", "openSocket('/ws/chat/$sid')") == [
        "WEBSOCKET /ws/chat/{}"
    ]


def test_does_not_flag_a_matching_route_with_other_verbs():
    server = '@app.get("/api/v1/x")\n@app.post("/api/v1/x")\n'
    assert contract_check.find_drift(server, "_post('/api/v1/x')") == []


def test_query_strings_are_ignored():
    server = '@app.get("/api/v1/files")\n'
    assert contract_check.find_drift(server, "_get('/api/v1/files?path=/a')") == []


def test_route_extraction_sees_both_ws_handlers_and_the_new_routes():
    routes = contract_check.server_routes(SERVER_SRC)
    assert ("WEBSOCKET", "/ws/chat/{}") in routes
    assert ("WEBSOCKET", "/ws/group/{}") in routes
    assert ("POST", "/api/v1/memory") in routes
    assert ("DELETE", "/api/v1/memory/{}") in routes
    assert ("POST", "/api/v1/cron") in routes
    assert ("POST", "/api/v1/servers") in routes
