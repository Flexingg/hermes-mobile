#!/usr/bin/env python3
"""Mutation-prove the fixes: break each one deliberately, confirm its test fails.

A green suite proves nothing on its own. For every security/behaviour fix in this
change, this script reverts the fix in place, runs the specific test that is
supposed to catch it, asserts the test FAILS, then restores the file.
"""
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path("/home/hermes/repos/hermes-mobile")
PY = "/home/hermes/.hermes/hermes-agent/venv/bin/python3"
FLUTTER = "/home/hermes/dev/flutter/bin/flutter"

BRIDGE = REPO / "server" / "bridge.py"
REPO_DART = REPO / "lib" / "data" / "hermes_repository.dart"
STATE_DART = REPO / "lib" / "state" / "app_state.dart"


def run_pytest(node: str) -> bool:
    p = subprocess.run([PY, "-m", "pytest", node, "-q"], cwd=REPO / "server",
                       capture_output=True, text=True, timeout=300)
    return p.returncode == 0


def run_flutter(name: str, file: str) -> bool:
    p = subprocess.run([FLUTTER, "test", file, "--plain-name", name],
                       cwd=REPO, capture_output=True, text=True, timeout=900)
    return p.returncode == 0


MUTATIONS = [
    # (label, file, old, new, runner, target, expected_before)
    (
        "html preview: token check removed",
        BRIDGE,
        '    if not _token_ok(_request_token(request)):\n        raise HTTPException(status_code=401, detail="unauthorized")\n    # {path:path} strips',
        '    # {path:path} strips',
        lambda: run_pytest("tests/test_auth.py::test_html_preview_requires_token"),
        "test_html_preview_requires_token",
        True,
    ),
    (
        "html preview: octet-stream fallback restored (the original leak)",
        BRIDGE,
        '    ctype = _PREVIEW_TYPES.get(p.suffix.lower())\n    if ctype is None:\n        raise HTTPException(status_code=404, detail="not a previewable file type")',
        '    ctype = _PREVIEW_TYPES.get(p.suffix.lower(), "application/octet-stream")',
        lambda: run_pytest("tests/test_auth.py::test_html_preview_refuses_non_preview_types"),
        "test_html_preview_refuses_non_preview_types",
        True,
    ),
    (
        "startup: BRIDGE_TOKEN no longer required",
        BRIDGE,
        'if not BRIDGE_TOKEN:\n    raise SystemExit(',
        'if False:\n    raise SystemExit(',
        lambda: run_pytest("tests/test_auth.py::test_refuses_to_start_without_token"),
        "test_refuses_to_start_without_token",
        True,
    ),
    (
        "websocket: authenticate after accept (i.e. not at all)",
        BRIDGE,
        '    if not _token_ok(_request_token(websocket)):\n        await websocket.close(code=1008)  # policy violation\n        return\n    await websocket.accept()\n    q: asyncio.Queue = asyncio.Queue()\n    _register_queue(session_id, q)',
        '    await websocket.accept()\n    q: asyncio.Queue = asyncio.Queue()\n    _register_queue(session_id, q)',
        lambda: run_pytest("tests/test_auth.py::test_websocket_requires_token"),
        "test_websocket_requires_token",
        True,
    ),
    (
        "cors: wildcard origin restored",
        BRIDGE,
        '    CORSMiddleware, allow_origins=CORS_ORIGINS, allow_methods=["*"], allow_headers=["*"]',
        '    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"]',
        lambda: run_pytest("tests/test_auth.py::test_no_wildcard_cors"),
        "test_no_wildcard_cors",
        True,
    ),
    (
        "duplicate /coach/sync-logs/health route reintroduced",
        BRIDGE,
        '@app.post("/api/v1/coach/sync-logs")\nasync def coach_sync_logs(body: dict | None = None):',
        '@app.get("/api/v1/coach/sync-logs/health")\ndef coach_sync_health():\n    return {"ok": True}\n\n\n@app.post("/api/v1/coach/sync-logs")\nasync def coach_sync_logs(body: dict | None = None):',
        lambda: run_pytest("tests/test_auth.py::test_no_duplicate_routes"),
        "test_no_duplicate_routes",
        True,
    ),
    (
        "memory delete: entries.pop() dropped (delete becomes a no-op)",
        BRIDGE,
        '    if idx >= len(entries):\n        raise HTTPException(status_code=404, detail="memory entry not found")\n    entries.pop(idx)',
        '    if idx >= len(entries):\n        raise HTTPException(status_code=404, detail="memory entry not found")',
        lambda: run_pytest("tests/test_routes.py::test_memory_add_appends_and_delete_removes"),
        "test_memory_add_appends_and_delete_removes",
        True,
    ),
    (
        "sparky 401 reported as 'unreachable' again",
        BRIDGE,
        '        if he.code in (401, 403):\n            raise SparkyAuthError(f"sparky rejected the token (HTTP {he.code})") from he\n        if he.code == 404:',
        '        if he.code in (401, 403):\n            raise SparkyUnreachableError("sparky unreachable") from he\n        if he.code == 404:',
        lambda: run_pytest("tests/test_routes.py::test_sparky_auth_error_is_not_reported_as_unreachable"),
        "test_sparky_auth_error_is_not_reported_as_unreachable",
        True,
    ),
    (
        "dart: previewUrl stops sending the token",
        REPO_DART,
        "    final t = token;\n    final query = (t == null || t.isEmpty) ? '' : '?token=${Uri.encodeQueryComponent(t)}';\n    return '$baseUrl/html/$segs$query';",
        "    return '$baseUrl/html/$segs';",
        lambda: run_flutter("carries the token as ?token=", "test/repository_test.dart"),
        "previewUrl carries the token",
        True,
    ),
    (
        "dart: downloadFile ApiFailure drops the server's detail",
        REPO_DART,
        "          throw ApiFailure('GET', '/api/v1/files', streamed.statusCode,\n              parseApiDetail(await streamed.stream.bytesToString()));",
        "          throw ApiFailure('GET', '/api/v1/files', streamed.statusCode, null);",
        lambda: run_flutter("carries the server detail", "test/repository_test.dart"),
        "ApiFailure carries the server detail",
        True,
    ),
    (
        "dart: websocket stops sending the bearer on the handshake",
        REPO_DART,
        "          headers: token == null ? null : {'Authorization': 'Bearer $token'},",
        "          headers: null,",
        lambda: run_flutter("sendMessage authenticates the upgrade", "test/repository_test.dart"),
        "sendMessage authenticates the upgrade and streams the reply",
        True,
    ),
    (
        "dart: AppState swallows the failure again (catch (_) {})",
        STATE_DART,
        "    try {\n      _groups = await repo.groups();\n      notifyListeners();\n    } catch (e) {\n      reportError(e, context: 'load groups');\n    }",
        "    try {\n      _groups = await repo.groups();\n      notifyListeners();\n    } catch (_) {}",
        lambda: run_flutter("a failing loader surfaces the error", "test/app_state_test.dart"),
        "AppState surfaces a failing loader",
        True,
    ),
]


def main() -> int:
    only = sys.argv[1] if len(sys.argv) > 1 else ""
    failures = []
    for label, path, old, new, runner, target, expect_before in MUTATIONS:
        if only and only not in label:
            continue
        backup = path.with_suffix(path.suffix + ".mutbak")
        src = path.read_text()
        if old not in src:
            print(f"SKIP  {label}: anchor not found")
            failures.append((label, "anchor not found"))
            continue
        shutil.copy2(path, backup)
        try:
            path.write_text(src.replace(old, new, 1))
            before = runner()
            result = "PROVEN" if (before is None or before) is False else "NOT PROVEN"
            if before:
                result = f"NOT PROVEN (test passed with the fix broken: {target})"
        finally:
            shutil.move(str(backup), str(path))
        ok = result == "PROVEN"
        print(f"{'PROVEN ' if ok else 'FAILED '} {label} -> {target} "
              f"(test {'failed' if ok else 'still passed'} with the fix reverted)")
        if not ok:
            failures.append((label, result))

    # Sanity: everything green again after restoring.
    print("\nrestored files; re-running both suites...")
    py_ok = run_pytest("tests")
    fl = subprocess.run([FLUTTER, "test"], cwd=REPO, capture_output=True, text=True, timeout=900)
    print(f"  pytest  : {'PASS' if py_ok else 'FAIL'}")
    print(f"  flutter : {'PASS' if fl.returncode == 0 else 'FAIL'}")

    if failures or not py_ok or fl.returncode != 0:
        print("\nRESULT: mutation proof INCOMPLETE")
        for label, why in failures:
            print(f"  - {label}: {why}")
        return 1
    print(f"\nRESULT: {len(MUTATIONS)}/{len(MUTATIONS)} mutations proven — "
          "every fix is load-bearing, and both suites are green again.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
