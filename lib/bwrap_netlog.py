#!/usr/bin/env python3
"""Network log helpers for the bw* sandbox launchers (see bwrap_sandbox_lib.sh,
"Network log").  Standard library only; runs on Python 3.6 (RHEL 8
platform-python) and later.

    bwrap_netlog.py condense --session ID [--dns-forward ADDR] -- CMD...
        Read pasta's debug log (and the DNS relay's lines) on standard input
        and write one line when a connection opens and one when it closes,
        with the DNS name of the destination when the relay saw it, to CMD's
        standard input (systemd-cat or logger).  Everything else pasta writes
        at debug level (timers, ACK and buffer bookkeeping, state changes,
        its setup dump) is dropped; its warnings and errors are kept.

    bwrap_netlog.py dns LISTEN UPSTREAM PARENT_PID
        A DNS relay for the sandbox's network namespace: listen on LISTEN
        (ADDR or ADDR:PORT, UDP and TCP), forward every query to UPSTREAM
        (pasta's DNS forward address) and print one line per query on
        standard output.  It exits when PARENT_PID (the descriptor relay,
        which becomes bwrap) does.

Output lines are logfmt (key=value), so Loki's `| logfmt` can filter them:

    session=ID flow=7 open proto=tcp dir=out src=... dst=140.82.113.22:443 name=github.com t=21.359
    session=ID flow=7 close proto=tcp dir=out dst=140.82.113.22:443 name=github.com t=33.770 secs=12.411
    session=ID flow=9 fail proto=tcp dir=out dst=192.0.2.1:443 src=... t=40.120
    session=ID dns name=github.com type=A rcode=NOERROR answers=140.82.113.22
"""

# Kept to what the DNS relay needs: it starts while the sandbox starts, and
# lookups made before it listens skip it (see bwrap_sandbox_lib.sh).
import ctypes
import os
import re
import signal
import socket
import struct
import sys
import threading

# ── condense ────────────────────────────────────────────────────────────

_TS = re.compile(r"^(\d+\.\d+):\s+(.*)$")
_FLOW = re.compile(r"^Flow (\d+) \((.*?)\):\s+(.*)$")
_ENDPOINTS = re.compile(
    r"^(\w+) \[([^\]]*)\]:(\d+) -> \[([^\]]*)\]:(\d+) => "
    r"(?:(\w+) \[([^\]]*)\]:(\d+) -> \[([^\]]*)\]:(\d+)|\?)$"
)
_HEADER = re.compile(r"^pasta (\S+): (\S+) \((\d+)\)$")
_DIRS = {
    ("TAP", "HOST"): "out",
    ("HOST", "SPLICE"): "publish",
    ("HOST", "TAP"): "publish",
    ("SPLICE", "HOST"): "host-port",
}


def _hostport(addr, port):
    if ":" in addr:
        return "[%s]:%s" % (addr, port)
    return "%s:%s" % (addr, port)


def _value(text):
    """A logfmt value: quoted when it contains a space, = or a quote."""
    if text and not re.search(r'[\s="]', text):
        return text
    return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')


class Condenser:
    """Turn pasta debug lines into open and close lines, one pair per flow."""

    def __init__(self, emit, dns_forward="169.254.1.1"):
        self.emit = emit
        self.dns_forward = dns_forward
        self.flows = {}
        self.names = {}
        self.last_t = 0.0
        self.header_seen = False

    def line(self, raw):
        raw = raw.rstrip("\n")
        if raw.startswith("event="):
            if raw.startswith("event=end"):
                self.finish()
            self.emit(raw, prefix=False)
            return
        if raw.startswith("bwrap-dns "):
            self._dns(raw[len("bwrap-dns ") :])
            return
        m = _HEADER.match(raw)
        if m and not self.header_seen:
            self.header_seen = True
            self.emit("pasta version=%s pid=%s" % (m.group(1), m.group(3)))
            return
        m = _TS.match(raw)
        if not m:
            return  # pasta's stderr copy of its setup, or noise
        t = float(m.group(1))
        self.last_t = max(self.last_t, t)
        rest = m.group(2)
        if rest.startswith(("ERROR:", "WARNING:")):
            level, _, msg = rest.partition(":")
            self.emit("pasta level=%s msg=%s t=%.3f" % (level.lower(), _value(msg.strip()), t))
            return
        m = _FLOW.match(rest)
        if m:
            self._flow(int(m.group(1)), m.group(2), m.group(3).strip(), t)

    def _dns(self, fields):
        kv = dict(re.findall(r'(\w+)=("(?:[^"\\]|\\.)*"|\S*)', fields))
        name = kv.get("name", "").strip('"')
        for a in kv.get("answers", "").split(","):
            if a and (re.match(r"^\d+\.\d+\.\d+\.\d+$", a) or ":" in a):
                self.names[a] = name
        self.emit("dns " + fields)

    def _flow(self, idx, kind, rest, t):
        f = self.flows.get(idx)
        if kind == "NEW":
            self.flows[idx] = {"t0": t}
            return
        if f is None:
            return
        if kind == "TGT":
            m = _ENDPOINTS.match(rest)
            if m and m.group(6):
                f.update(
                    ini=m.group(1),
                    src=(m.group(2), m.group(3)),
                    dst=(m.group(4), m.group(5)),
                    tgt=m.group(6),
                    tdst=(m.group(9), m.group(10)),
                )
            return
        if kind == "FREE":
            if rest.endswith("-> FREE"):
                del self.flows[idx]
                if f.get("open"):
                    self._close(idx, f, t)
                elif "ini" in f and not self._is_dns_forward(f):
                    # Never became active: a refused or failed connection.
                    self.emit(" ".join(self._fields(idx, f, "fail") + ["src=%s" % _hostport(*f["src"]), "t=%.3f" % t]))
            return
        # A typed flow: "TCP connection", "TCP connection (spliced)", "UDP flow", ...
        if rest == "TGT -> TYPED":
            f["proto"] = kind.split()[0].lower()
        elif rest == "TYPED -> ACTIVE" and "ini" in f:
            self._open(idx, f, t)

    def _fields(self, idx, f, event):
        direction = _DIRS.get((f["ini"], f["tgt"]), "%s-%s" % (f["ini"].lower(), f["tgt"].lower()))
        parts = ["flow=%d" % idx, event, "proto=%s" % f.get("proto", "?"), "dir=%s" % direction]
        if event == "open":
            parts.append("src=%s" % _hostport(*f["src"]))
        parts.append("dst=%s" % _hostport(*f["dst"]))
        if f["tdst"][0] != f["dst"][0] and f["tdst"][0] not in ("0.0.0.0", "::"):
            parts.append("via=%s" % _hostport(*f["tdst"]))
        name = self.names.get(f["dst"][0])
        if name and direction == "out":
            parts.append("name=%s" % _value(name))
        return parts

    def _is_dns_forward(self, f):
        # pasta's own leg of a lookup the relay already logged as a dns line.
        return f.get("proto") == "udp" and f["dst"] == (self.dns_forward, "53")

    def _open(self, idx, f, t):
        f["open"] = True
        if self._is_dns_forward(f):
            return
        self.emit(" ".join(self._fields(idx, f, "open") + ["t=%.3f" % t]))

    def _close(self, idx, f, t, reason=None):
        if self._is_dns_forward(f):
            return
        parts = self._fields(idx, f, "close") + ["t=%.3f" % t, "secs=%.3f" % (t - f["t0"])]
        if reason:
            parts.append("reason=%s" % reason)
        self.emit(" ".join(parts))

    def finish(self):
        """Close the flows still open when the session ends."""
        for idx in sorted(self.flows):
            f = self.flows[idx]
            if f.get("open"):
                self._close(idx, f, self.last_t, reason="session-end")
        self.flows.clear()


def condense(argv):
    import subprocess

    session, dns_forward, cmd = "", "169.254.1.1", []
    i = 0
    while i < len(argv):
        if argv[i] == "--session":
            session = argv[i + 1]
            i += 2
        elif argv[i] == "--dns-forward":
            dns_forward = argv[i + 1]
            i += 2
        elif argv[i] == "--":
            cmd = argv[i + 1 :]
            break
        else:
            sys.exit("bwrap_netlog condense: unknown argument %r" % argv[i])
    sink = None
    if cmd:
        sink = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    out = sink.stdin if sink else sys.stdout.buffer
    state = {"dead": False}

    def emit(text, prefix=True):
        if state["dead"]:
            return
        if prefix and session:
            text = "session=%s %s" % (session, text)
        try:
            out.write((text + "\n").encode("utf-8", "replace"))
            out.flush()
        except (BrokenPipeError, OSError):
            # The log tool is gone: keep reading, so pasta never blocks.
            state["dead"] = True

    c = Condenser(emit, dns_forward)
    for raw in sys.stdin.buffer:
        try:
            c.line(raw.decode("utf-8", "replace"))
        except Exception as e:  # never stop reading pasta's log
            emit("condense level=error msg=%s" % _value(repr(e)))
    c.finish()
    if sink:
        try:
            sink.stdin.close()
        except OSError:
            pass
        sink.wait()


# ── dns relay ───────────────────────────────────────────────────────────

_QTYPES = {1: "A", 2: "NS", 5: "CNAME", 6: "SOA", 12: "PTR", 15: "MX", 16: "TXT", 28: "AAAA", 33: "SRV", 65: "HTTPS"}
_RCODES = {0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN", 4: "NOTIMP", 5: "REFUSED"}


def _read_name(msg, off):
    """Read a (possibly compressed) domain name at OFF; return (name, next offset)."""
    labels, jumped, end, hops = [], False, off, 0
    while True:
        if off >= len(msg) or hops > 64:
            raise ValueError("bad name")
        n = msg[off]
        if n == 0:
            off += 1
            break
        if n & 0xC0 == 0xC0:
            if off + 1 >= len(msg):
                raise ValueError("bad pointer")
            if not jumped:
                end = off + 2
            off = ((n & 0x3F) << 8) | msg[off + 1]
            jumped, hops = True, hops + 1
            continue
        labels.append(msg[off + 1 : off + 1 + n].decode("ascii", "replace"))
        off += 1 + n
    return ".".join(labels) or ".", (end if jumped else off)


def parse_query(msg):
    """Return (name, type) of the first question of a DNS message."""
    if len(msg) < 12 or struct.unpack("!H", msg[4:6])[0] < 1:
        raise ValueError("no question")
    name, off = _read_name(msg, 12)
    qtype = struct.unpack("!H", msg[off : off + 2])[0]
    return name.lower(), _QTYPES.get(qtype, str(qtype))


def parse_answers(msg):
    """Return (rcode, [answers]) of a DNS response: A, AAAA and CNAME data."""
    if len(msg) < 12:
        raise ValueError("short response")
    flags, qd, an = struct.unpack("!HHH", msg[2:8])
    off = 12
    for _ in range(qd):
        _, off = _read_name(msg, off)
        off += 4
    answers = []
    for _ in range(an):
        _, off = _read_name(msg, off)
        rtype, _, _, rdlen = struct.unpack("!HHIH", msg[off : off + 10])
        off += 10
        rdata = msg[off : off + rdlen]
        if rtype == 1 and rdlen == 4:
            answers.append(socket.inet_ntop(socket.AF_INET, rdata))
        elif rtype == 28 and rdlen == 16:
            answers.append(socket.inet_ntop(socket.AF_INET6, rdata))
        elif rtype == 5:
            answers.append(_read_name(msg, off)[0].lower())
        off += rdlen
    return _RCODES.get(flags & 0xF, str(flags & 0xF)), answers


def _addr(spec, port=53):
    host, sep, p = spec.rpartition(":")
    if sep and p.isdigit() and host.count(":") == 0:
        return host, int(p)
    return spec, port


class DnsRelay:
    def __init__(self, listen, upstream, out=None):
        self.listen = _addr(listen)
        self.upstream = _addr(upstream)
        self.out = out or sys.stdout
        self.lock = threading.Lock()

    def log(self, query, response, proto):
        try:
            name, qtype = parse_query(query)
        except (ValueError, struct.error, IndexError):
            name, qtype = "?", "?"
        if response is None:
            rcode, answers = "TIMEOUT", []
        else:
            try:
                rcode, answers = parse_answers(response)
            except (ValueError, struct.error, IndexError):
                rcode, answers = "UNPARSED", []
        line = "bwrap-dns name=%s type=%s proto=%s rcode=%s answers=%s\n" % (
            _value(name),
            qtype,
            proto,
            rcode,
            ",".join(answers) or "-",
        )
        with self.lock:
            try:
                self.out.write(line)
                self.out.flush()
            except OSError:
                pass

    def _udp_one(self, srv, query, client):
        response = None
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.settimeout(5)
            s.connect(self.upstream)
            s.send(query)
            response = s.recv(65535)
            s.close()
            srv.sendto(response, client)
        except OSError:
            pass
        self.log(query, response, "udp")

    def _recv_exact(self, s, n):
        data = b""
        while len(data) < n:
            chunk = s.recv(n - len(data))
            if not chunk:
                raise OSError("closed")
            data += chunk
        return data

    def _tcp_one(self, conn):
        try:
            conn.settimeout(10)
            up = socket.create_connection(self.upstream, timeout=5)
            while True:
                try:
                    hdr = self._recv_exact(conn, 2)
                except OSError:
                    break
                query = self._recv_exact(conn, struct.unpack("!H", hdr)[0])
                up.sendall(hdr + query)
                rhdr = self._recv_exact(up, 2)
                response = self._recv_exact(up, struct.unpack("!H", rhdr)[0])
                conn.sendall(rhdr + response)
                self.log(query, response, "tcp")
            up.close()
        except OSError:
            pass
        finally:
            conn.close()

    def bind(self):
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind(self.listen)
        self.tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.tcp.bind(self.listen)
        self.tcp.listen(16)

    def serve(self):
        def tcp_loop():
            while True:
                conn, _ = self.tcp.accept()
                threading.Thread(target=self._tcp_one, args=(conn,), daemon=True).start()

        threading.Thread(target=tcp_loop, daemon=True).start()
        while True:
            query, client = self.udp.recvfrom(65535)
            threading.Thread(target=self._udp_one, args=(self.udp, query, client), daemon=True).start()


def _drop_capabilities():
    """Drop every capability (the relay runs as root of pasta's user namespace;
    it needs CAP_NET_BIND_SERVICE only to bind port 53, which is done)."""
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        header = struct.pack("II", 0x20080522, 0)  # _LINUX_CAPABILITY_VERSION_3, this thread
        data = ctypes.create_string_buffer(24)  # 2 x {effective, permitted, inheritable}
        libc.capset(ctypes.create_string_buffer(header), data)
        libc.prctl(38, 1, 0, 0, 0)  # PR_SET_NO_NEW_PRIVS
    except (OSError, AttributeError):
        pass


def dns(argv):
    listen, upstream, parent = argv[0], argv[1], int(argv[2])
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        libc.prctl(1, signal.SIGTERM, 0, 0, 0)  # PR_SET_PDEATHSIG
    except (OSError, AttributeError):
        pass
    if os.getppid() != parent:
        return
    relay = DnsRelay(listen, upstream)
    try:
        relay.bind()
    except OSError as e:
        sys.stdout.write("bwrap-dns name=- type=- proto=- rcode=RELAY-FAILED answers=%s\n" % _value(str(e)))
        sys.stdout.flush()
        return
    _drop_capabilities()
    try:  # tell the descriptor relay, which waits for this, that it listens
        os.write(3, b"ready\n")
        os.close(3)
    except OSError:
        pass
    relay.serve()


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "condense":
        condense(sys.argv[2:])
    elif len(sys.argv) == 5 and sys.argv[1] == "dns":
        try:
            dns(sys.argv[2:])
        except KeyboardInterrupt:
            pass
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
