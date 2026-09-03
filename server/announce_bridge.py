#!/usr/bin/env python3
"""Advertise the Mercury bridge over mDNS/DNS-SD (RFC 6762).

A self-contained, dependency-free responder so the Mercury Messenger app can
auto-find this bridge on the local network via its "Search your network"
action. It publishes:

    _mercury._tcp.local.            (PTR)  ->  Mercury._mercury._tcp.local.
    Mercury._mercury._tcp.local.    (SRV)  ->  <host>.local.:9130  (+TXT)
    <host>.local.                   (A)    ->  <primary LAN IPv4>

It is deliberately minimal and pure-stdlib: it answers mDNS queries on BOTH
IPv4 and IPv6 link-local multicast (so Android NSD / Apple Bonjour browse
queries are always seen) and sends an unsolicited announcement on start.
No Avahi, no sudo, no pip packages — it runs as the same user as the bridge.

Interop notes (why these choices matter):
- Android NSD (NsdManager, used by bonsoir) only registers a service when the
  PTR browse answer carries the SRV/TXT/A in the *Additional* section, so every
  PTR response appends them.
- Modern Android often browses over IPv6 link-local multicast (ff02::fb), so we
  answer there too even though the host only carries an IPv4 (A) record.
- Name compression is not used in answers (fully-qualified names) — simpler and
  unambiguous.
"""

import argparse
import fcntl
import os
import select
import signal
import socket
import struct
import sys

_MCAST_PORT = 5353
_V4_GRP = "224.0.0.251"
_V6_GRP = "ff02::fb"
_MDNS_HEADER = 12
_FLUSH = 0x8000  # cache-flush bit (set in multicast responses)


def _qname_encode(name: str) -> bytes:
    out = bytearray()
    for label in name.rstrip(".").split("."):
        b = label.encode("ascii")
        out.append(len(b))
        out += b
    out.append(0)
    return bytes(out)


def _default_iface() -> str:
    """Name of the interface holding the default route (or '')."""
    try:
        with open("/proc/net/route") as fh:
            for line in fh.readlines()[1:]:
                p = line.split()
                if len(p) > 1 and p[1] == "00000000":
                    return p[0]
    except OSError:
        pass
    return ""


def _iface_ipv4(iface: str) -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        return socket.inet_ntoa(
            fcntl.ioctl(sock.fileno(), 0x8915,  # SIOCGIFADDR
                        struct.pack("256s", iface.encode()[:15]))[20:24])
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


def _primary_ipv4() -> str:
    """IPv4 of the default-route interface (what LAN clients can reach)."""
    iface = _default_iface()
    if iface:
        ip = _iface_ipv4(iface)
        if not ip.startswith("127."):
            return ip
    # Fallback: ask the kernel which address reaches a public host.
    try:
        tmp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            tmp.connect(("8.8.8.8", 80))
            return tmp.getsockname()[0]
        finally:
            tmp.close()
    except OSError:
        return "127.0.0.1"


def _hostname() -> str:
    hn = socket.gethostname().split(".")[0] or "hermes"
    hn = hn.strip("-")[:63]
    return hn + ".local"


def _make_socket(family, reuse=True):
    sock = socket.socket(family, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    if reuse:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if hasattr(socket, "SO_REUSEPORT"):
            try:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            except OSError:
                pass
    return sock


class MdnsAdvertiser:
    def __init__(self, instance: str, type_: str, port: int, txt: dict):
        self.instance = instance
        segs = type_.lstrip("_").split("._")
        self.type_name = f"_{segs[0]}._tcp.local."
        self.port = port
        self.host = _hostname()
        self.ip = _primary_ipv4()
        self.fqdn = f"{self.instance}.{self.type_name}"
        self.txt = txt
        self.iface = _default_iface()

        self.socks = []  # (socket, is_v6, mcast_group, scope_ifindex)
        self._setup_v4()
        self._setup_v6()

    # ---- socket setup -----------------------------------------------------
    def _setup_v4(self):
        sock = _make_socket(socket.AF_INET)
        sock.bind(("", _MCAST_PORT))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL,
                        struct.pack("B", 255))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP,
                        struct.pack("B", 1))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                        socket.inet_aton(_V4_GRP) + socket.inet_aton("0.0.0.0"))
        sock.settimeout(0.2)
        self.socks.append([sock, False, _V4_GRP, 0])

    def _setup_v6(self):
        if not hasattr(socket, "AF_INET6"):
            return
        idx = 0
        if self.iface:
            try:
                idx = socket.if_nametoindex(self.iface)
            except OSError:
                idx = 0
        sock = None
        try:
            sock = _make_socket(socket.AF_INET6)
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            sock.bind(("::", _MCAST_PORT))
            mreq = socket.inet_pton(socket.AF_INET6, _V6_GRP) + struct.pack("@I", idx)
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_JOIN_GROUP, mreq)
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_LOOP, 1)
            if idx:
                sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF,
                                struct.pack("@I", idx))
            sock.settimeout(0.2)
            self.socks.append([sock, True, _V6_GRP, idx])
        except OSError:
            if sock is not None:
                try:
                    sock.close()
                except Exception:
                    pass

    # ---- record builders (name, qtype, class, ttl, rdata) ----------------
    def _ptr(self):
        return (_qname_encode(self.type_name), 12, 0x0001, 4500,
                _qname_encode(self.fqdn))

    def _srv(self):
        rd = struct.pack(">HHH", 0, 0, self.port) + _qname_encode(self.host)
        return (_qname_encode(self.fqdn), 33, 0x0001, 120, rd)

    def _txt(self):
        rd = b"".join(
            bytes([min(len(str(k)) + len(str(v)) + 1, 255)])
            + (str(k) + "=" + str(v)).encode("utf-8")[:255]
            for k, v in self.txt.items())
        if not rd:
            rd = b"\x00"
        return (_qname_encode(self.fqdn), 16, 0x0001, 4500, rd)

    def _a(self):
        return (_qname_encode(self.host), 1, 0x0001, 120,
                socket.inet_aton(self.ip))

    def _all(self):
        return [self._ptr(), self._srv(), self._txt(), self._a()]

    # ---- response assembly ------------------------------------------------
    def _respond(self, qname_bytes: bytes, qtype: int):
        """Return (answers, additionals) for a question, or (None, None)."""
        base = qname_bytes.decode("ascii", "replace").lower().rstrip(".")
        fqdn = self.fqdn.rstrip(".").lower()
        type_n = self.type_name.rstrip(".").lower()
        host = self.host.rstrip(".").lower()

        if base == type_n and qtype in (12, 255):       # PTR / ANY on type
            return [self._ptr()], [self._srv(), self._txt(), self._a()]
        if base == fqdn:
            if qtype == 33:                              # SRV
                return [self._srv()], [self._a()]
            if qtype == 16:                              # TXT
                return [self._txt()], []
            if qtype == 12:                              # PTR on instance
                return [self._ptr()], [self._srv(), self._txt(), self._a()]
            if qtype == 255:                             # ANY on instance
                return [self._srv(), self._txt(), self._a()], []
        if base == host and qtype in (1, 255):           # A / ANY on host
            return [self._a()], []
        return None, None

    def _send(self, sock, is_v6, mcast_group, ifidx, answers, additionals,
              to_multicast, dest=None):
        if not answers and not additionals:
            return
        out = bytearray()
        out += struct.pack(">HHHHHH", 0, 0x8400, 0,
                           len(answers), 0, len(additionals))
        flush = 0x8000 if to_multicast else 0x0000
        for rec in answers + additionals:
            name, qtype, cls, ttl, rd = rec
            out += name
            out += struct.pack(">HHIH", qtype, flush | cls, ttl, len(rd))
            out += rd
        if to_multicast:
            if is_v6:
                dest = (mcast_group, _MCAST_PORT, 0, ifidx)
            else:
                dest = (mcast_group, _MCAST_PORT)
        try:
            sock.sendto(bytes(out), dest)
        except OSError:
            pass

    def _multicast_dest(self, entry):
        if entry[1]:
            return (entry[2], _MCAST_PORT, 0, entry[3])
        return (entry[2], _MCAST_PORT)

    # ---- query decoding ----------------------------------------------------
    def _query_name(self, data: bytes, offset: int):
        labels = []
        pos = offset
        end = None
        jumps = 0
        while True:
            ln = data[pos]
            if ln & 0xC0 == 0xC0:  # compression pointer
                ptr = struct.unpack(">H", data[pos:pos + 2])[0] & 0x3FFF
                if end is None:
                    end = pos + 2
                pos = ptr
                jumps += 1
                if jumps > 8:
                    break
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

    # ---- main loop ----------------------------------------------------------
    def run(self):
        # Unsolicited announcements so phones discover it without querying.
        for entry in self.socks:
            self._send(entry[0], entry[1], entry[2], entry[3],
                       self._all(), [], True)
        while True:
            try:
                r, _, _ = select.select([e[0] for e in self.socks], [], [], 0.5)
            except (OSError, ValueError):
                return
            for sock in r:
                # Which logical entry does this fd belong to?
                entry = next((e for e in self.socks if e[0] is sock), None)
                if entry is None:
                    continue
                try:
                    data, addr = sock.recvfrom(65535)
                except OSError:
                    continue
                try:
                    self._handle(entry, data, addr)
                except Exception:
                    continue

    def _handle(self, entry, data, addr):
        sock, is_v6, mcast_group, ifidx = entry
        if len(data) < _MDNS_HEADER + 4:
            return
        try:
            (_, flags, qd, an, ns, ar) = struct.unpack(">HHHHHH", data[0:12])
        except struct.error:
            return
        if flags & 0x8000:  # it's already a response; ignore
            return
        pos = 12
        answers = []
        additionals = []
        unicast_reply = False
        for _ in range(qd):
            qname, pos = self._query_name(data, pos)
            if pos is None or pos + 4 > len(data):
                return
            qtype, qclass = struct.unpack(">HH", data[pos:pos + 4])
            pos += 4
            if qclass & 0x8000:  # QU: client wants a unicast reply
                unicast_reply = True
            a, add = self._respond(qname.encode("ascii", "replace"), qtype)
            if a:
                answers += a
                if add:
                    additionals += add
        if not answers:
            return
        if unicast_reply:
            # Legacy unicast reply, no cache-flush bit.
            self._send(sock, is_v6, mcast_group, ifidx, answers, additionals,
                       False, dest=addr)
        else:
            self._send(sock, is_v6, mcast_group, ifidx, answers, additionals,
                       True)


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
    print(f"Advertising {adv.fqdn} (SRV -> {adv.host}:{args.port}, "
          f"A -> {adv.ip}, iface={adv.iface})", flush=True)

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
