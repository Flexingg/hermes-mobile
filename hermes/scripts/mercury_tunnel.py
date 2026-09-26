#!/usr/bin/env python3
"""Reach the bridge from anywhere without Tailscale: a Cloudflare tunnel.

    mercury_tunnel.py up [--hostname bridge.example.com] [--port 9130]
    mercury_tunnel.py down
    mercury_tunnel.py status

Two shapes of tunnel, picked automatically:

* **named tunnel** — when a hostname is given (or `MERCURY_TUNNEL_HOSTNAME` is
  set) *and* `~/.cloudflared/config.yml` exists. The URL is
  `https://<hostname>`, stable across restarts, and can be put behind Cloudflare
  Access so the edge itself refuses unauthenticated requests. Set it up once:

      cloudflared tunnel login
      cloudflared tunnel create mercury
      cloudflared tunnel route dns mercury bridge.example.com
      # ~/.cloudflared/config.yml:
      #   tunnel: mercury
      #   credentials-file: /home/you/.cloudflared/<uuid>.json
      #   ingress:
      #     - hostname: bridge.example.com
      #       service: http://127.0.0.1:9130
      #     - service: http_status:404

* **quick tunnel** — otherwise. Free, no account or domain: cloudflared prints a
  random `https://<words>.trycloudflare.com` URL. It changes every start, and the
  edge does not authenticate anyone on it, so the bridge's BRIDGE_TOKEN is the only
  gate. Fine for trying it; use a named tunnel + Access for anything lasting.

Either way cloudflared dials *out* to Cloudflare and forwards to
`http://127.0.0.1:<port>`, so the bridge stays bound to loopback and no inbound
port is opened. The URL it produced is written to `~/.hermes/mercury/tunnel.json`,
which the bridge serves read-only at `GET /api/v1/tunnel` for the app.

The tunnel is a systemd --user unit (`mercury-tunnel`) when systemd is available,
so it is a service that survives the run that started it, restarts nothing by
accident, and can be stopped by name. Where it isn't (a container, a bare shell),
the process is started detached and its pid is recorded instead. `down` stops
exactly what `up` started — never anything else.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import time
from pathlib import Path

from mercury_common import MERCURY_HOME, REAL_HOME, MercuryError, emit, main_guard

STATE = MERCURY_HOME / "tunnel.json"
LOG = MERCURY_HOME / "tunnel.log"
# REAL_HOME, not Path.home(): kanban workers and cron runs have a per-profile
# HOME, and cloudflared's config lives in the real user's home.
CLOUDFLARED_CONFIG = Path(os.environ.get("MERCURY_CLOUDFLARED_CONFIG")
                          or REAL_HOME / ".cloudflared" / "config.yml")
UNIT = os.environ.get("MERCURY_TUNNEL_UNIT") or "mercury-tunnel"
QUICK_URL_RE = re.compile(r"https://[a-z0-9][a-z0-9-]*\.trycloudflare\.com")
# cloudflared's own progress lines are the only place the quick URL appears.
READY_TIMEOUT = 45


def cloudflared() -> str:
    return os.environ.get("MERCURY_CLOUDFLARED") or "cloudflared"


# -- state --------------------------------------------------------------------
def read_state() -> dict:
    try:
        return json.loads(STATE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def write_state(data: dict) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_name(STATE.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
    os.replace(tmp, STATE)


# -- liveness ------------------------------------------------------------------
def pid_is_cloudflared(pid: int) -> bool:
    """True when this pid exists and is a cloudflared process (a recycled pid or
    an exited quick tunnel must not be advertised as a working URL)."""
    if pid <= 0:
        return False
    try:
        return "cloudflared" in Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="ignore")
    except OSError:
        return False


def run(cmd: list[str], timeout: int = 30, check: bool = False) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError as exc:
        raise MercuryError(f"not found: {cmd[0]}") from exc
    except subprocess.TimeoutExpired:
        raise MercuryError(f"timed out: {' '.join(cmd[:3])}") from exc


def systemd_available() -> bool:
    # MERCURY_TUNNEL_SYSTEMD=0 forces the detached-process path (containers, tests,
    # host without a user manager).
    if (os.environ.get("MERCURY_TUNNEL_SYSTEMD") or "").strip().lower() in ("0", "no", "false"):
        return False
    if not shutil.which("systemd-run") or not shutil.which("systemctl"):
        return False
    return run(["systemctl", "--user", "show", "-p", "Version"]).stdout.startswith("Version=")


def unit_main_pid() -> int:
    out = run(["systemctl", "--user", "show", "-p", "MainPID", UNIT]).stdout
    try:
        return int(out.strip().split("=", 1)[1] or 0)
    except (IndexError, ValueError):
        return 0


def unit_url_from_journal(since: float) -> str | None:
    """The quick-tunnel URL cloudflared logged to the unit's journal *this* run.

    The journal is append-only, so the query is bounded to the moment this unit
    was started: without that, the URL printed by an earlier run is found first
    and the phone is sent to a tunnel that no longer exists.
    """
    out = run(["journalctl", "--user", "-u", UNIT, "--since", f"@{int(since) - 1}",
               "--no-pager", "-o", "cat"]).stdout
    found = QUICK_URL_RE.findall(out or "")
    return found[-1] if found else None


def active() -> tuple[bool, int]:
    """(is a tunnel running, its cloudflared pid)."""
    state = read_state()
    if state.get("mode") == "systemd":
        pid = unit_main_pid()
        if pid and pid_is_cloudflared(pid):
            return True, pid
        return False, 0
    pid = int(state.get("pid") or 0)
    return (True, pid) if pid_is_cloudflared(pid) else (False, 0)


# -- commands -------------------------------------------------------------------
def cmd_status(a) -> int:
    state = read_state()
    up, pid = active()
    hostname = (a.hostname or os.environ.get("MERCURY_TUNNEL_HOSTNAME") or "").strip() or None
    return emit({"ok": True, "up": up, "kind": state.get("kind") if up else None,
                 "url": (f"https://{hostname}" if (up and hostname) else state.get("url")) if up else None,
                 "hostname": state.get("hostname") if up else None,
                 "mode": state.get("mode") if up else None,
                 "pid": pid or None, "port": state.get("port"),
                 "startedAt": state.get("startedAt") if up else None,
                 "accessProtected": bool(state.get("accessProtected")) if up else False})


def cmd_down(a) -> int:
    state = read_state()
    stopped, how = False, None
    if state.get("mode") == "systemd":
        if run(["systemctl", "--user", "stop", UNIT]).returncode == 0:
            stopped, how = True, f"systemd unit {UNIT}"
        run(["systemctl", "--user", "reset-failed", UNIT])
    else:
        pid = int(state.get("pid") or 0)
        if pid_is_cloudflared(pid):
            os.kill(pid, signal.SIGTERM)
            for _ in range(20):
                if not pid_is_cloudflared(pid):
                    break
                time.sleep(0.25)
            if pid_is_cloudflared(pid):
                os.kill(pid, signal.SIGKILL)
            stopped, how = True, f"pid {pid}"
    STATE.unlink(missing_ok=True)
    return emit({"ok": True, "stopped": stopped, "how": how,
                 "note": None if stopped else "no tunnel was running"})


def cmd_up(a) -> int:
    up, pid = active()
    if up:
        # Never start a second one: report the tunnel that is already there.
        return cmd_status(a)
    hostname = (a.hostname or os.environ.get("MERCURY_TUNNEL_HOSTNAME") or "").strip() or None
    named = bool(hostname and CLOUDFLARED_CONFIG.exists())
    if hostname and not named:
        raise MercuryError(
            f"--hostname {hostname} needs {CLOUDFLARED_CONFIG} "
            "(cloudflared tunnel create + route dns); omit it for a quick tunnel")
    if named:
        # The hostname and its ingress rule come from cloudflared's own config.
        tunnel_cmd = [cloudflared(), "tunnel", "--no-autoupdate", "run"]
    else:
        tunnel_cmd = [cloudflared(), "tunnel", "--no-autoupdate", "--url", f"http://127.0.0.1:{a.port}"]
    if not shutil.which(cloudflared()):
        raise MercuryError(f"cloudflared is not installed ({cloudflared()})")

    if systemd_available():
        url, pid = _up_systemd(tunnel_cmd, named)
        mode = "systemd"
    else:
        url, pid = _up_process(tunnel_cmd, named)
        mode = "process"
    if named:
        url = f"https://{hostname}"
    if not url:
        _stop(mode)
        raise MercuryError("cloudflared came up but never printed a URL")
    state = {"mode": mode, "unit": UNIT if mode == "systemd" else None, "kind": "named" if named else "quick",
             "url": url, "hostname": hostname, "pid": pid, "port": a.port, "startedAt": time.time(),
             "accessProtected": bool(named and os.environ.get("MERCURY_TUNNEL_ACCESS")),
             "log": str(LOG) if mode == "process" else None}
    write_state(state)
    return emit({"ok": True, **{k: v for k, v in state.items() if k != "log"},
                 "note": (f"reaches the bridge at 127.0.0.1:{a.port}; BRIDGE_TOKEN still guards "
                          "the API, and Cloudflare does not authenticate anyone on a quick tunnel"
                          if not named else
                          f"reaches the bridge at 127.0.0.1:{a.port}; put a Cloudflare Access "
                          "policy in front of it for edge authentication")})


def _stop(mode: str) -> None:
    if mode == "systemd":
        run(["systemctl", "--user", "stop", UNIT])
    else:
        state = read_state()
        pid = int(state.get("pid") or 0)
        if pid_is_cloudflared(pid):
            os.kill(pid, signal.SIGKILL)


def _up_systemd(tunnel_cmd: list[str], named: bool) -> tuple[str | None, int]:
    """Start cloudflared as a transient systemd --user unit.

    A service, not an orphan: it outlives the run that started it (a chat turn, a
    cron tick), and `down` can stop it by name.
    """
    run(["systemctl", "--user", "reset-failed", UNIT])
    started = time.time()
    p = run(["systemd-run", "--user", "--unit", UNIT, "--collect", "--quiet", *tunnel_cmd], timeout=30)
    if p.returncode != 0:
        raise MercuryError(f"systemd-run failed: {(p.stderr or p.stdout or '').strip()[:300]}")
    url = None
    deadline = started + READY_TIMEOUT
    while time.time() < deadline:
        pid = unit_main_pid()
        if named and pid:
            return None, pid
        url = None if named else unit_url_from_journal(started)
        # The MainPID itself must be cloudflared: a unit that failed to exec would
        # otherwise look ready.
        if url and pid and pid_is_cloudflared(pid):
            return url, pid
        time.sleep(0.5)
    return url, unit_main_pid()


def _up_process(tunnel_cmd: list[str], named: bool) -> tuple[str | None, int]:
    """Fallback: a detached cloudflared process, for hosts without a user manager."""
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as log:
        proc = subprocess.Popen(tunnel_cmd, stdout=log, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, start_new_session=True)
    url, deadline = None, time.time() + READY_TIMEOUT
    while time.time() < deadline:
        if proc.poll() is not None:
            raise MercuryError(f"cloudflared exited ({proc.returncode}); see {LOG}")
        text = LOG.read_text(encoding="utf-8", errors="ignore")
        found = QUICK_URL_RE.findall(text)
        if found:
            url = found[-1]
            break
        if named:
            return None, proc.pid
        time.sleep(0.5)
    return url, proc.pid


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    up = sub.add_parser("up", help="start a tunnel (quick, or named when a hostname is configured)")
    up.add_argument("--hostname", help="the named tunnel's hostname (needs ~/.cloudflared/config.yml)")
    up.add_argument("--port", type=int, default=int(os.environ.get("MERCURY_BRIDGE_PORT", "9130")))
    down = sub.add_parser("down", help="stop the tunnel this state file names")
    down.add_argument("--hostname", help=argparse.SUPPRESS)
    st = sub.add_parser("status", help="is a tunnel up, and what is its URL")
    st.add_argument("--hostname", help=argparse.SUPPRESS)
    a = ap.parse_args()
    if a.cmd == "up":
        return main_guard(lambda: cmd_up(a))
    return main_guard(lambda: {"down": cmd_down, "status": cmd_status}[a.cmd](a))


if __name__ == "__main__":
    raise SystemExit(main())
