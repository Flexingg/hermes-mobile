"""Test bootstrap for the bridge.

The bridge refuses to import without a token and reads everything from
$HERMES_HOME, so BOTH must be set before `import bridge` — pointing HERMES_HOME
at a throwaway directory keeps the suite away from the real ~/.hermes (live
chat history, memory files, cron jobs).
"""
import os
import sys
import tempfile
from pathlib import Path

_TMP = Path(tempfile.mkdtemp(prefix="mercury-bridge-tests-"))
os.environ["HERMES_HOME"] = str(_TMP)
os.environ["BRIDGE_TOKEN"] = "test-token-0123456789abcdef"
os.environ["HERMES_BIN"] = "/bin/false"  # never shell out to the real CLI

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import bridge  # noqa: E402

TOKEN = os.environ["BRIDGE_TOKEN"]


def auth(token: str = TOKEN) -> dict:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def client():
    return TestClient(bridge.app)


@pytest.fixture(autouse=True)
def _isolated_stores(tmp_path, monkeypatch):
    """Every test gets its own store files: nothing touches real Hermes state."""
    monkeypatch.setattr(bridge, "MEM_DIR", tmp_path / "memories")
    monkeypatch.setattr(bridge, "CRON_JOBS", tmp_path / "cron" / "jobs.json")
    monkeypatch.setattr(bridge, "SERVER_STORE", tmp_path / "mercury_servers.json")
    monkeypatch.setattr(bridge, "STATE_DB", tmp_path / "state.db")
    monkeypatch.setattr(bridge, "SKILLS_DIR", tmp_path / "skills")
    monkeypatch.setattr(bridge, "PROFILES_DIR", tmp_path / "profiles")
    yield
