#!/usr/bin/env python3
"""Network log helpers for the bw* sandbox launchers (see bwrap_sandbox_lib.sh,
"Network log").  Standard library only; runs on Python 3.6 (RHEL 8
platform-python) and later.

    bwrap_netlog.py condense --session ID [--dns-forward ADDR]
        [--fifo PATH --parent PID [--marker TEXT] [--end-record TEXT]
         [--session-dir DIR] [--backend NAME]] -- CMD...
        Read pasta's debug output (its stderr, and the DNS relay's lines) and
        write one line when a connection opens and one when it closes, with
        the domain of the destination when the relay saw it, to CMD's
        standard input (systemd-cat or logger).  Everything else pasta writes
        at debug level (timers, ACK and buffer bookkeeping, state changes,
        its setup dump) is dropped.  Without --fifo it filters standard
        input; with it, it reads the FIFO (see the launcher's "Network log")
        until the launcher, PID, has exited, then writes the end record.

    bwrap_netlog.py dns LISTEN UPSTREAM PARENT_PID [UDP_FD TCP_FD]
        A DNS relay for the sandbox's network namespace: listen on LISTEN
        (ADDR or ADDR:PORT, UDP and TCP), forward every query to UPSTREAM
        (the backend's DNS address) and print one line per query on standard
        output.  It exits when PARENT_PID (the descriptor relay, which
        becomes bwrap) does.  UDP_FD and TCP_FD are sockets already bound to
        LISTEN, for a namespace where this process cannot bind port 53
        itself; "-" means bind here (see DnsRelay.adopt).

Output lines are logfmt (key=value), so Loki's `| logfmt` can filter them:

    session=ID flow=7 open proto=tcp dir=out src=... dst=140.82.113.22:443 domain=github.com t=21.359
    session=ID flow=7 close proto=tcp dir=out dst=140.82.113.22:443 domain=github.com t=33.770 secs=12.411
    session=ID flow=9 fail proto=tcp dir=out dst=192.0.2.1:443 src=... t=40.120
    session=ID dns domain=github.com type=A rcode=NOERROR answers=140.82.113.22
    session=ID dns domain=api.x.com type=A rcode=NOERROR answers=192.0.2.1 cname=lb.x.net
"""

# Kept to what the DNS relay needs: it starts while the sandbox starts, and
# lookups made before it listens skip it (see bwrap_sandbox_lib.sh).
import ctypes
import ipaddress
from concurrent.futures import ThreadPoolExecutor
import os
import re
import signal
import socket
import struct
import sys
import threading

# ── condense ────────────────────────────────────────────────────────────

# pasta's debug lines on stderr (log.c vlogmsg): "T: message", T in seconds
# since pasta started.  (In its --log-file a level column follows the
# timestamp; \s+ absorbs it, should a log file ever be fed in.)
_TS = re.compile(r"^(\d+\.\d+):\s+(.*)$")
_FLOW = re.compile(r"^Flow (\d+) \((.*?)\):\s+(.*)$")
_ENDPOINTS = re.compile(
    r"^(\w+) \[([^\]]*)\]:(\d+) -> \[([^\]]*)\]:(\d+) => "
    r"(?:(\w+) \[([^\]]*)\]:(\d+) -> \[([^\]]*)\]:(\d+)|\?)$"
)
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
    # DNS labels are arbitrary bytes, not necessarily valid hostnames.  Never
    # allow one to turn into a second journal record or a terminal control.
    text = "".join("\\x%02x" % ord(c) if ord(c) < 32 or ord(c) == 127 else c for c in text)
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
        m = _TS.match(raw)
        if not m:
            return  # not a pasta debug line (a message from the relay, noise)
        t = float(m.group(1))
        self.last_t = max(self.last_t, t)
        m = _FLOW.match(m.group(2))
        if m:
            self._flow(int(m.group(1)), m.group(2), m.group(3).strip(), t)

    def _dns(self, fields):
        kv = dict(re.findall(r'(\w+)=("(?:[^"\\]|\\.)*"|\S*)', fields))
        name = kv.get("domain", "").strip('"')
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
            parts.append("domain=%s" % _value(name))
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


def _parent_is(pid):
    """True while PID is our parent: then it is alive and its pid cannot have
    been reused (the launcher keeps its pid through exec; when it exits we
    are re-parented)."""
    return os.getppid() == pid


class FifoReader:
    """Read lines from a FIFO without ever blocking its writer.

    The FIFO is opened read-only and non-blocking: a read-only reader sees
    EOF whenever no writer has it open, which happens before the launcher
    opens its stderr on it and, briefly, if pasta is ever without the fd.
    So EOF is not the end: `lines()` keeps polling until `done()` says the
    session is over, and then drains what is left.  The launcher opens its
    end only after this reader exists (it is told, see `ready`), so its
    write-only open does not block.
    """

    def __init__(self, path, done):
        import select

        self.fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        self.done = done
        self.poll = select.poll()
        self.poll.register(self.fd, select.POLLIN)
        self.buf = b""

    def _read(self, timeout_ms):
        """Return the bytes available within TIMEOUT_MS; b"" when none.
        Waits out TIMEOUT_MS even while the FIFO reports hang-up (no writer),
        which poll() would otherwise report at once, over and over."""
        import time

        deadline = time.monotonic() + timeout_ms / 1000.0
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return b""
            if self.poll.poll(int(left * 1000)):
                try:
                    data = os.read(self.fd, 65536)
                except (BlockingIOError, InterruptedError):
                    data = b""
                if data:
                    return data
                time.sleep(min(0.05, max(left, 0)))  # hang-up: no writer yet, or none left

    def lines(self, poll_ms=1000):
        """Yield complete lines (without the newline) until the session is
        over and the FIFO is drained."""
        while True:
            data = self._read(poll_ms)
            if data:
                self.buf += data
                while b"\n" in self.buf:
                    line, _, self.buf = self.buf.partition(b"\n")
                    yield line.decode("utf-8", "replace")
                continue
            if self.done():
                break
        # The writers are gone; whatever they left is read at once.
        while True:
            data = self._read(200)
            if not data:
                break
            self.buf += data
        for line in self.buf.split(b"\n"):
            if line:
                yield line.decode("utf-8", "replace")
        self.buf = b""
        os.close(self.fd)


def _bridge_stderr(path, stop):
    """Copy PATH (a FIFO the relay opens as the sandbox's stderr when the
    user's is a pipe) to our stderr until STOP is set and it is drained."""
    reader = FifoReader(path, stop.is_set)
    for line in reader.lines():
        try:
            sys.stderr.write(line + "\n")
            sys.stderr.flush()
        except (OSError, ValueError):
            pass


def condense(argv):
    """Condense pasta's debug log into the system log.

    Run by the launcher in the background, before it opens its stderr on the
    FIFO and execs pasta.  It reads the FIFO itself, writes one record per
    connection to CMD (systemd-cat or logger), writes the end record once the
    launcher (then pasta) has exited, and removes the session directory.
    The relay prints MARKER on pasta's stderr when the sandbox is about to
    start; pasta's lines before it are its setup and, if it fails, its error:
    they go to the terminal (this process's stderr) when the launcher exits
    without the marker ever arriving.
    """
    import subprocess

    session, dns_forward, cmd = "", "169.254.1.1", []
    fifo, parent, marker, end_record, session_dir, stderr_fifo = None, None, None, None, None, None
    backend = "pasta"
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--session":
            session = argv[i + 1]
        elif a == "--dns-forward":
            dns_forward = argv[i + 1]
        elif a == "--fifo":
            fifo = argv[i + 1]
        elif a == "--parent":
            parent = int(argv[i + 1])
        elif a == "--marker":
            marker = argv[i + 1]
        elif a == "--end-record":
            end_record = argv[i + 1]
        elif a == "--session-dir":
            session_dir = argv[i + 1]
        elif a == "--stderr-fifo":
            stderr_fifo = argv[i + 1]
        elif a == "--backend":
            backend = argv[i + 1]
        elif a == "--":
            cmd = argv[i + 1 :]
            break
        else:
            sys.exit("bwrap_netlog condense: unknown argument %r" % a)
        i += 2
    if fifo is not None and parent is None:
        sys.exit("bwrap_netlog condense: --fifo needs --parent")

    # Signals meant for the session (Ctrl-C on the terminal, a hangup, a kill
    # of the process group) must not cost the end record: this process ends
    # by itself once the launcher has gone.
    for sig in (signal.SIGINT, signal.SIGQUIT, signal.SIGHUP, signal.SIGTERM, signal.SIGPIPE):
        try:
            signal.signal(sig, signal.SIG_IGN)
        except (OSError, ValueError):
            pass
    try:
        signal.signal(signal.SIGTSTP, signal.SIG_IGN)
    except (OSError, ValueError, AttributeError):
        pass

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

    def feed(raw):
        try:
            c.line(raw)
        except Exception as e:  # never stop reading pasta's log
            emit("condense level=error msg=%s" % _value(repr(e)))

    if fifo is None:
        # Plain filter: standard input to the log (tests, by hand).
        for raw in sys.stdin.buffer:
            feed(raw.decode("utf-8", "replace"))
    else:
        reader = FifoReader(fifo, lambda: not _parent_is(parent))
        bridge, bridge_stop = None, threading.Event()
        if stderr_fifo:
            bridge = threading.Thread(target=_bridge_stderr, args=(stderr_fifo, bridge_stop))
            bridge.daemon = True
            bridge.start()
        # The launcher waits for this before it opens its stderr on the FIFO.
        try:
            os.write(3, b"ready\n")
            os.close(3)
        except OSError:
            pass
        started, early = marker is None, []
        for raw in reader.lines():
            if not started:
                if raw == marker:
                    started = True
                    early = []
                    continue
                if len(early) < 200:
                    early.append(raw)
            feed(raw)
        if not started:
            # The backend stopped before starting the sandbox: show what it
            # said (pasta's own lines; with slirp4netns, the identity
            # mapper's or the descriptor relay's).
            for raw in early:
                sys.stderr.write("%s: %s\n" % (backend, raw))
            sys.stderr.flush()
        if bridge:
            bridge_stop.set()
            bridge.join(5)
    c.finish()
    if end_record:
        emit(end_record, prefix=False)
    if sink:
        try:
            sink.stdin.close()
        except OSError:
            pass
        sink.wait()
    if session_dir:
        import shutil

        shutil.rmtree(session_dir, ignore_errors=True)


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
    def __init__(self, listen, upstream, out=None, workers=16, pending=32):
        self.listen = _addr(listen)
        self.upstream = _addr(upstream)
        self.out = out or sys.stdout
        self.lock = threading.Lock()
        self.slots = threading.BoundedSemaphore(workers + pending)
        self.pool = ThreadPoolExecutor(max_workers=workers, thread_name_prefix="bwrap-dns")
        self.stopping = threading.Event()

    def _submit(self, fn, *args):
        if not self.slots.acquire(False):
            return False
        try:
            future = self.pool.submit(fn, *args)
        except RuntimeError:
            self.slots.release()
            return False
        future.add_done_callback(lambda _: self.slots.release())
        return True

    def close(self):
        self.stopping.set()
        for sock in (getattr(self, "udp", None), getattr(self, "tcp", None)):
            if sock is not None:
                sock.close()
        self.pool.shutdown(wait=True)

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
        addrs, cnames = [], []
        for a in answers:
            try:
                ipaddress.ip_address(a)
            except ValueError:
                cnames.append(a)
            else:
                addrs.append(a)
        line = "bwrap-dns domain=%s type=%s proto=%s rcode=%s answers=%s%s\n" % (
            _value(name),
            qtype,
            proto,
            rcode,
            ",".join(addrs) or "-",
            " cname=%s" % _value(",".join(cnames)) if cnames else "",
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
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.settimeout(5)
                s.connect(self.upstream)
                s.send(query)
                response = s.recv(65535)
        except OSError:
            pass
        # Log before answering: the client connects as soon as it has the
        # answer, and the condenser must know the name by then.
        self.log(query, response, "udp")
        if response is not None:
            try:
                srv.sendto(response, client)
            except OSError:
                pass

    def _recv_exact(self, s, n):
        data = b""
        while len(data) < n:
            chunk = s.recv(n - len(data))
            if not chunk:
                raise OSError("closed")
            data += chunk
        return data

    def _tcp_one(self, conn):
        with conn:
            conn.settimeout(10)
            while True:
                try:
                    hdr = self._recv_exact(conn, 2)
                    query = self._recv_exact(conn, struct.unpack("!H", hdr)[0])
                    # DNS servers may close after one response.  A fresh
                    # connection per query also avoids replaying a request
                    # after an ambiguous upstream failure.
                    with socket.create_connection(self.upstream, timeout=5) as up:
                        up.settimeout(10)
                        up.sendall(hdr + query)
                        rhdr = self._recv_exact(up, 2)
                        response = self._recv_exact(up, struct.unpack("!H", rhdr)[0])
                    self.log(query, response, "tcp")
                    conn.sendall(rhdr + response)
                except OSError:
                    break

    def _overloaded(self, query, client):
        # A quick SERVFAIL gives clients a chance to use their next resolver.
        # Only respond when we can safely copy a single complete question.
        try:
            if len(query) < 12 or struct.unpack("!H", query[4:6])[0] != 1:
                return
            _, end = _read_name(query, 12)
            end += 4  # QTYPE and QCLASS
            if end > len(query):
                return
            flags = struct.unpack("!H", query[2:4])[0]
            reply = query[:2] + struct.pack("!HHHHH", 0x8002 | (flags & 0x0100), 1, 0, 0, 0) + query[12:end]
            self.log(query, reply, "udp")
            self.udp.sendto(reply, client)
        except (ValueError, struct.error, OSError, IndexError):
            pass

    def bind(self):
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind(self.listen)
        self.tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        # Port zero is useful for isolated tests; TCP must share UDP's port.
        self.tcp.bind(self.udp.getsockname())
        self.tcp.listen(16)

    def adopt(self, udp_fd, tcp_fd):
        """Take over sockets bound before the exec that dropped our privileges.

        Binding port 53 needs CAP_NET_BIND_SERVICE.  With pasta, whose
        namespace maps the caller to uid 0, the relay binds for itself
        (bind()).  With slirp4netns the namespace maps the real uid, and after
        the exec chain the relay holds no capabilities (seen: CapEff 0, the
        bind refused), so the process that creates the namespace binds the
        sockets and hands them over here (see _NET_NS_IDENTITY in
        bwrap_sandbox_lib.sh).
        """
        self.udp = socket.fromfd(udp_fd, socket.AF_INET, socket.SOCK_DGRAM)
        self.tcp = socket.fromfd(tcp_fd, socket.AF_INET, socket.SOCK_STREAM)
        # fromfd duplicates; the inherited numbers are not needed again.
        os.close(udp_fd)
        os.close(tcp_fd)
        self.listen = self.udp.getsockname()

    def serve(self):
        def tcp_loop():
            while not self.stopping.is_set():
                try:
                    conn, _ = self.tcp.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                if not self._submit(self._tcp_one, conn):
                    conn.close()

        self.tcp.settimeout(0.2)
        self.udp.settimeout(0.2)
        tcp_thread = threading.Thread(target=tcp_loop, daemon=True)
        tcp_thread.start()
        try:
            while not self.stopping.is_set():
                try:
                    query, client = self.udp.recvfrom(65535)
                except socket.timeout:
                    continue
                except OSError:
                    break
                if not self._submit(self._udp_one, self.udp, query, client):
                    self._overloaded(query, client)
        finally:
            tcp_thread.join()
            self.close()


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
    # Optional pre-bound sockets, "-" when this process may bind for itself.
    fds = None
    if len(argv) >= 5 and argv[3] != "-":
        fds = (int(argv[3]), int(argv[4]))
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        libc.prctl(1, signal.SIGTERM, 0, 0, 0)  # PR_SET_PDEATHSIG
    except (OSError, AttributeError):
        pass
    if os.getppid() != parent:
        return
    relay = DnsRelay(listen, upstream)
    try:
        if fds is None:
            relay.bind()
        else:
            relay.adopt(*fds)
    except OSError as e:
        sys.stdout.write("bwrap-dns domain=- type=- proto=- rcode=RELAY-FAILED answers=%s\n" % _value(str(e)))
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
    elif len(sys.argv) in (5, 7) and sys.argv[1] == "dns":
        try:
            dns(sys.argv[2:])
        except KeyboardInterrupt:
            pass
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
