#!/usr/bin/env python3
"""Contract check: every bridge route the app calls must exist on the bridge.

Why this exists: the app shipped nine client calls to routes the bridge never
implemented ("add server", "add/edit/delete memory", "create/edit/delete cron
job", "toggle skill"). Nothing caught it — the app threw a bare `Exception` and
the UI swallowed it, so a whole management screen looked like it worked. This
compares the two route sets and exits non-zero on drift, so the next phantom
call fails CI instead of failing silently on the phone.

No dependencies: it parses the two files as text, so it runs under plain
python3 (CI does not need the server's venv).

Usage:  python3 tools/contract_check.py [--repo ROOT] [--verbose]
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SERVER = Path("server") / "bridge.py"
CLIENT = Path("lib") / "data" / "hermes_repository.dart"

# @app.get("/api/v1/sessions/{session_id}/messages")
_ROUTE_RE = re.compile(r'@app\.(get|post|patch|delete|put|websocket)\(\s*"([^"]+)"')
# _get('/api/v1/x')  |  _post('/api/v1/x', …)  |  _client.get(Uri.parse('$baseUrl/api/v1/x'))
_CALL_RE = re.compile(
    r'(?:\b_client\s*\.\s*|\b_)\s*(get|post|patch|delete)\(\s*(?:Uri\.parse\()?\s*[\'"]((?:\$baseUrl)?[^\'"]+)[\'"]',
    re.IGNORECASE,
)
# http.Request('GET', uri) / MultipartRequest('POST', Uri.parse('$baseUrl/api/v1/…'))
_RAW_RE = re.compile(
    r"""(?:http\.Request|MultipartRequest)\(\s*['"](\w+)['"]\s*,\s*Uri\.parse\(\s*['"]([^'"]+)['"]""",
)
# openSocket('/ws/chat/$sessionId')
_SOCKET_RE = re.compile(r'openSocket\(\s*[\'"]([^\'"]+)[\'"]')
# Any other '$baseUrl/…' literal (e.g. `final uri = Uri.parse('$baseUrl/api/v1/files?path=…')`),
# where the surrounding verb is not visible: checked by path alone.
_ANY_URL_RE = re.compile(r'[\'"](?:\$baseUrl)?(/(?:api/v1|html|ws)[^\'"\s]*)')

_INTERP_RE = re.compile(r"\$\{[^}]+\}|\$[A-Za-z_][A-Za-z0-9_]*")


def _template(path: str) -> str:
    """Normalise a route path to a comparable template.

    `/api/v1/sessions/{session_id}/messages` and
    `/api/v1/sessions/$sessionId/messages` both become
    `/api/v1/sessions/{}//messages`.
    """
    p = path.split("?")[0].strip()
    p = p.replace("$baseUrl", "")
    p = _INTERP_RE.sub("{}", p)
    p = re.sub(r"\{[^}]+\}", "{}", p)
    p = re.sub(r"(?:\{\})+", "{}", p)
    p = re.sub(r"/+", "/", p)
    return p.rstrip("/") or "/"


def _is_concrete(path: str) -> bool:
    """False for the repository's own private helpers, whose path is a variable.

    `_client.get(Uri.parse('$baseUrl$path'))` normalises to `{}` — a template with
    no literal segment tells us nothing, so it must not be reported as drift.
    """
    return bool(re.search(r"[A-Za-z0-9]", path))


def server_routes(text: str) -> set[tuple[str, str]]:
    out = set()
    for verb, path in _ROUTE_RE.findall(text):
        out.add((verb.upper(), _template(path)))
    return out


def client_calls(text: str) -> set[tuple[str, str]]:
    out = set()
    for verb, path in _CALL_RE.findall(text):
        if not path.startswith("/") and not path.startswith("$baseUrl"):
            continue
        out.add((verb.upper(), _template(path)))
    for verb, path in _RAW_RE.findall(text):
        out.add((verb.upper(), _template(path)))
    for path in _SOCKET_RE.findall(text):
        out.add(("WEBSOCKET", _template(path)))
    return out


def client_paths(text: str) -> set[str]:
    """Every client-side bridge path, verb or not (bellwether for typos)."""
    return {_template(p) for p in _ANY_URL_RE.findall(text)}


def find_drift(server_text: str, client_text: str) -> list[str]:
    routes = server_routes(server_text)
    served_paths = {path for _verb, path in routes}
    # A route may exist with a different verb only if the app's verb is served
    # by something else on the same path — keep it strict: verb+path must match.
    missing = []
    reported: set[str] = set()
    for verb, path in sorted(client_calls(client_text)):
        if not _is_concrete(path):
            continue
        reported.add(path)
        if (verb, path) not in routes:
            missing.append(f"{verb:9} {path}")
    for path in sorted(client_paths(client_text) - served_paths):
        if _is_concrete(path) and path not in reported:
            missing.append(f"{'(path)':9} {path}")
    return missing


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=str(Path(__file__).resolve().parents[1]))
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    root = Path(args.repo)
    server_text = (root / SERVER).read_text()
    client_text = (root / CLIENT).read_text()

    routes = server_routes(server_text)
    calls = client_calls(client_text)
    missing = find_drift(server_text, client_text)

    if args.verbose:
        print(f"server routes : {len(routes)}")
        print(f"client calls  : {len(calls)}")

    if missing:
        print("DRIFT — the app calls routes the bridge does not implement:")
        for m in missing:
            print(f"  {m}")
        print("\nImplement the route in server/bridge.py, or delete the client "
              "method. Do not leave it silently failing.")
        return 1

    print(f"contract ok: {len(calls)} client calls all exist "
          f"({len(routes)} server routes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
