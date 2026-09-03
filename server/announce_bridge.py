#!/usr/bin/env python3
"""Advertise the Mercury bridge over mDNS/DNS-SD (RFC 6762).

A self-contained, dependency-free responder so the Mercury Messenger app can
auto-find this bridge on the local network via its "Search your network"
action. It publishes:

    _mercury._tcp.local.            (PTR)  ->  Mercury._mercury._tcp.local.
    Mercury._mercury._tcp.local.    (SRV)  ->  <host>.local.:9130  (+TXT)
    <host>.local.                   (A)    ->  <primary LAN IPv4>

It is deliberately minimal and pure-stdlib: it answers mDNS queries (PTR/SRV/
TXT/A) on the multicast group and sends an unsolicited announcement on start.
No Avahi, no sudo, no pip packages — it runs as the same user as the bridge.

Only handles the common unicast-response path (class IN, cache-flush answers)
well enough for Android NSD / Apple Bonjour browsing. Name compression is NOT
used in answers (writes fully-qualified names) — a little larger but simpler
and unambiguous.
"""

import argparse
import fcntl
import os
import signal
import socket
import socket as s
import struct
import sys
import time

_MCAST_GRP = "224.0.0.251"
_MCAST_PORT = 5353
_MDNS_HEADER = 12
_FLUSH = 0x8000  # cache-flush bit for answers in legacy-unicast responses


def _qname_encode(name: str) -> bytes:
    out = bytearray()
    for label in name.rstrip(".").split("."):
        b = label.encode("ascii")
        out.append(len(b))
        out += b
    out.append(0)
    return bytes(out)


def _primary_ipv4() -> str:
    """Return the IPv4 of the interface holding the default route."""
    # /proc/net/route: iface, dest, gateway, flags, ...
    try:
        with open("/proc/net/route", "r") as fh:
            for line in fh.readlines()[1:]:
                parts = line.split()
                if not parts:
                    continue
                dest = parts[1]
                if dest == "00000000":  # default route
                    iface = parts[0]
                    return _iface_ipv4(iface)
    except (OSError, IndexError):
        pass
    # Fallback: ask the kernel which address would reach a public host.
    try:
        tmp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            tmp.connect(("8.8.8.8", 80))
            return tmp.getsockname()[0]
        finally:
            tmp.close()
    except OSError:
        return "127.0.0.1"


def _iface_ipv4(iface: str) -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        return socket.inet_ntoa(
            fcntl.ioctl(
                sock.fileno(), 0x8915,  # SIOCGIFADDR
                struct.pack("256s", iface.encode()[:15]),
            )[20:24]
        )
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


def _hostname() -> str:
    hn = socket.gethostname().split(".")[0] or "hermes"
    # mDNS names must be < 63 chars and not end in '-'.
    hn = hn.strip("-")[:63]
    return hn + ".local"


class MdnsAdvertiser:
    def __init__(self, instance: str, type_: str, port: int, txt: dict):
        self.instance = instance
        self.service_type = type_.lstrip("_").split("._")  # e.g. ["mercury","tcp"]
        self.type_name = f"_{self.service_type[0]}._tcp.local."
        self.port = port
        self.host = _hostname()
        self.ip = _primary_ipv4()
        self.fqdn = f"{self.instance}.{self.type_name}"
        self.txt = txt
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if hasattr(socket, "SO_REUSEPORT"):
            try:
                self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            except OSError:
                pass
        self.sock.bind(("", _MCAST_PORT))
        self._ttl = struct.pack("B", 255)
        self.sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, self._ttl)
        self.sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                             socket.inet_aton(_MCAST_GRP) + socket.inet_aton("0.0.0.0"))
        self.sock.settimeout(0.5)

    # ---- record builders -------------------------------------------------
    def _ptr(self):
        return (_qname_encode(self.type_name), 12, 0x8000 | 0x0001, 4500,
                _qname_encode(self.fqdn))

    def _srv(self):
        rd = struct.pack(">HHH", 0, 0, self.port) + _qname_encode(self.host)
        return (_qname_encode(self.fqdn), 33, 0x8000 | 0x0001, 120, rd)

    def _txt(self):
        rd = b"".join(
            bytes([min(len(str(k)) + len(str(v)) + 1, 255)])
            + (str(k) + "=" + str(v)).encode("utf-8")[:255]
            for k, v in self.txt.items()
        )
        if not rd:
            rd = b"\x00"
        return (_qname_encode(self.fqdn), 16, 0x8000 | 0x0001, 4500, rd)

    def _a(self):
        return (_qname_encode(self.host), 1, 0x8000 | 0x0001, 120,
                socket.inet_aton(self.ip))

    def _respond(self, qname_bytes: bytes, qtype: int):
        """Return an answer record matching qname/qtype, or None."""
        name = qname_bytes.decode("ascii", "replace").lower()
        # Strip trailing dot; also try instance-less type queries.
        base = name.rstrip(".")
        fqdn = self.fqdn.rstrip(".").lower()
        type_n = self.type_name.rstrip(".").lower()
        host = self.host.rstrip(".").lower()
        if base == type_n and qtype in (12, 255):  # PTR / ANY
            return self._ptr()
        if base == fqdn and qtype in (33, 16, 255):
            if qtype == 16:
                return self._txt()
            if qtype == 255:
                return self._ptr()
            return self._srv()
        if base == host and qtype in (1, 255):  # A / ANY
            return self._a()
        # Some clients ask with the instance name but PTR type directly.
        if base == fqdn and qtype == 12:
            return self._ptr()
        return None

    def _all_records(self):
        return [self._ptr(), self._srv(), self._txt(), self._a()]

    def _send(self, answers, to=None):
        if not answers:
            return
        out = bytearray()
        out += struct.pack(">HHHHHH", 0, 0x8400, 0, len(answers), 0, 0)  # response
        for name, qtype, flags, ttl, rd in answers:
            out += name
            out += struct.pack(">HHIH", qtype, flags, ttl, len(rd))
            out += rd
        dest = to or (_MCAST_GRP, _MCAST_PORT)
        try:
            self.sock.sendto(bytes(out), dest)
        except OSError:
            pass

    def _query_name(self, data: bytes, offset: int):
        """Decode a possibly-compressed DNS name from data starting at offset."""
        labels = []
        jumps = 0
        pos = offset
        end = None
        while True:
            ln = data[pos]
            if ln & 0xC0 == 0xC0:  # compression pointer
                ptr = struct.unpack(">H", data[pos:pos + 2])[0] & 0x3FFF
                if end is None:
                    end = pos + 2
                jumps += 1
                if jumps > 8:
                    break
                pos = ptr
                continue
            if ln == 0:
                if end is None:
                    end = pos + 1
                break
            pos += 1
            labels.append(data[pos:pos + ln].decode("ascii", "replace"))
            pos += ln
            if jumps > 8:
                break
        return ".".join(labels), (end if end is not None else pos)

    def run(self, once=False):
        # Unsolicited announcement so phones discover it immediately.
        self._send(self._all_records())
        while True:
            try:
                data, addr = self.sock.recvfrom(65535)
            except socket.timeout:
                if once:
                    return
                continue
            except OSError:
                return
            self._handle(data, addr)
            if once:
                return

    def _handle(self, data, addr):
        if len(data) < _MDNS_HEADER + 4:
            return
        try:
            (_, flags, qd, an, ns, ar) = struct.unpack(">HHHHHH", data[0:12])
        except struct.error:
            return
        if flags & 0x8000:  # this is a response; ignore (probing, etc.)
            return
        pos = 12
        answers = []
        for _ in range(qd):
            qname, pos = self._query_name(data, pos)
            if pos is None or pos + 4 > len(data):
                return
            qtype, qclass = struct.unpack(">HH", data[pos:pos + 4])
            pos += 4
            if qclass != 1 and qclass != 0x8001:  # IN
                continue
            rec = self._respond(qname.encode("ascii", "replace"), qtype)
            if rec is not None:
                answers.append(rec)
        if answers:
            # Reply to multicast queries via multicast (unless legacy unicast
            # bit set on the query), else unicast to the source.
            if flags & 0x0001 or addr[0] == _MCAST_GRP:
                self._send(answers)
            else:
                self._send(answers, to=addr)


def main():
    ap = argparse.ArgumentParser(description="Mercury bridge mDNS advertiser")
    ap.add_argument("--port", type=int, default=9130)
    ap.add_argument("--instance", default="Mercury")
    ap.add_argument("--name", default=None, help="Optional display name in TXT")
    ap.add_argument("--pidfile")
    args = ap.parse_args()

    txt = {}
    if args.name:
        txt["name"] = args.name
        txt["app"] = "mercury"

    adv = MdnsAdvertiser(args.instance, "_mercury._tcp", args.port, txt)
    print(f"Advertising {adv.fqdn} (SRV -> {adv.host}:{args.port}, A -> {adv.ip})",
          flush=True)

    if args.pidfile:
        with open(args.pidfile, "w") as f:
            f.write(str(os.getpid()))

    def _stop(*_):
        sys.exit(0)

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    try:
        adv.run()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
