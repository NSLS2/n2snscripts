"""Tests for lib/bwrap_netlog.py (the network log condenser and DNS relay).

    python3 -m unittest discover -s tests -p 'test_*.py'

tests/data/pasta-debug.log is part of a real pasta 2026_10_02 debug log
and tests/data/pasta-stderr.log is a whole short one, both as pasta writes
them to stderr with --debug and no --log-file ("T: message"), addresses of
the host replaced with documentation addresses.
"""

import io
import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import bwrap_netlog as netlog  # noqa: E402

FIXTURE = os.path.join(HERE, "data", "pasta-debug.log")
FIXTURE_STDERR = os.path.join(HERE, "data", "pasta-stderr.log")


def condense(lines):
    out = []
    c = netlog.Condenser(lambda text, prefix=True: out.append(text))
    for line in lines:
        c.line(line)
    c.finish()
    return out


def query(name, qtype=1, tid=0x1234):
    body = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0"
    return struct.pack("!HHHHHH", tid, 0x0100, 1, 0, 0, 0) + body + struct.pack("!HH", qtype, 1)


def answer(q):
    """A CNAME to example.org and A 192.0.2.10, with compressed names."""
    end = 12
    while q[end]:
        end += 1 + q[end]
    end += 5
    cname = bytes([7]) + b"example" + bytes([3]) + b"org" + b"\0"
    rr1 = b"\xc0\x0c" + struct.pack("!HHIH", 5, 1, 60, len(cname)) + cname
    rr2 = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + socket.inet_aton("192.0.2.10")
    return q[:2] + struct.pack("!HHHHH", 0x8180, 1, 2, 0, 0) + q[12:end] + rr1 + rr2


class CondenserTest(unittest.TestCase):
    def setUp(self):
        with open(FIXTURE) as f:
            self.raw = f.read().splitlines()
        self.out = condense(self.raw)

    def flows(self, event):
        return [line for line in self.out if " %s " % event in line and line.startswith("flow=")]

    def test_much_shorter(self):
        self.assertLess(len(self.out), len(self.raw) / 5)

    def test_one_open_and_one_close_per_flow(self):
        opens, closes = self.flows("open"), self.flows("close")
        self.assertTrue(opens)
        self.assertEqual(len(opens), len(closes))
        active = sum(1 for line in self.raw if line.endswith("TYPED -> ACTIVE"))
        dns = sum(1 for line in self.raw if re.search(r"\(TGT\):\s+TAP \S+ -> \[169\.254\.1\.1\]:53 ", line))
        self.assertEqual(len(opens), active - dns)

    def test_close_has_duration(self):
        for line in self.flows("close"):
            self.assertRegex(line, r" t=\d+\.\d{3} secs=\d+\.\d{3}")

    def test_open_has_endpoints(self):
        line = next(x for x in self.flows("open") if "dst=140.82.112.21:443" in x)
        self.assertIn("proto=tcp dir=out src=198.51.100.7:", line)

    def test_ipv6_in_brackets(self):
        self.assertTrue(any("dst=[2606:4700:10::ac42:ad95]:443" in x for x in self.out))

    def test_setup_and_noise_dropped(self):
        text = "\n".join(self.out)
        for noise in ("Template interface", "timer expires", "STALLED", "ACK_FROM_TAP_DUE", "hash table"):
            self.assertNotIn(noise, text)

    def test_dns_forward_flows_dropped(self):
        self.assertFalse(any("169.254.1.1:53" in x for x in self.out))

    def test_only_flows_and_dns(self):
        for line in self.out:
            self.assertRegex(line, r"^(flow=\d+ (open|close|fail) |dns )")

    def test_real_stderr_capture(self):
        with open(FIXTURE_STDERR) as f:
            out = condense(f.read().splitlines() + ["event=end session=x"])
        self.assertEqual(
            out,
            [
                "flow=0 open proto=tcp dir=out src=[2001:db8::7]:40506 dst=[2001:db8:1::2]:443 t=0.069",
                "flow=0 close proto=tcp dir=out dst=[2001:db8:1::2]:443 t=0.494 secs=0.425 reason=session-end",
                "event=end session=x",
            ],
        )

    def test_names_from_dns(self):
        out = condense(["bwrap-dns domain=github.com type=A proto=udp rcode=NOERROR answers=140.82.112.21"] + self.raw)
        self.assertEqual(out[0], "dns domain=github.com type=A proto=udp rcode=NOERROR answers=140.82.112.21")
        line = next(x for x in out if " open " in x and "dst=140.82.112.21:443" in x)
        self.assertTrue(line.endswith("domain=github.com t=0.917"), line)

    def test_publish_and_host_port(self):
        t = "1.0000:          Flow 3 "
        out = condense(
            [
                t + "(NEW): FREE -> NEW",
                t
                + "(TGT):     HOST [127.0.0.1]:5000 -> [127.65.81.1]:8000 => SPLICE [0.0.0.0]:0 -> [198.51.100.7]:8000",
                t + "(TCP connection (spliced)): TGT -> TYPED",
                t + "(TCP connection (spliced)): TYPED -> ACTIVE",
                "2.5000:          Flow 3 (FREE): ACTIVE -> FREE",
            ]
        )
        self.assertEqual(
            out,
            [
                "flow=3 open proto=tcp dir=publish src=127.0.0.1:5000 dst=127.65.81.1:8000 via=198.51.100.7:8000 t=1.000",
                "flow=3 close proto=tcp dir=publish dst=127.65.81.1:8000 via=198.51.100.7:8000 t=2.500 secs=1.500",
            ],
        )

    def test_host_port_translation_keeps_the_port(self):
        # --host-port 5432:15432: the sandbox connects to 127.0.0.1:15432 and
        # pasta carries it to the host's 127.0.0.1:5432; the address is the
        # same on both sides, the port is not.
        t = "1.0000:          Flow 4 "
        out = condense(
            [
                t + "(NEW): FREE -> NEW",
                t + "(TGT):     SPLICE [127.0.0.1]:40000 -> [127.0.0.1]:15432 => HOST [0.0.0.0]:0 -> [127.0.0.1]:5432",
                t + "(TCP connection (spliced)): TGT -> TYPED",
                t + "(TCP connection (spliced)): TYPED -> ACTIVE",
                "2.0000:          Flow 4 (FREE): ACTIVE -> FREE",
            ]
        )
        self.assertEqual(
            out,
            [
                "flow=4 open proto=tcp dir=host-port src=127.0.0.1:40000 dst=127.0.0.1:15432 via=127.0.0.1:5432 t=1.000",
                "flow=4 close proto=tcp dir=host-port dst=127.0.0.1:15432 via=127.0.0.1:5432 t=2.000 secs=1.000",
            ],
        )

    def test_failed_connection(self):
        t = "1.0000:          Flow 2 "
        out = condense(
            [
                t + "(NEW): FREE -> NEW",
                t + "(TGT):     TAP [198.51.100.7]:5000 -> [192.0.2.1]:443 => HOST [0.0.0.0]:0 -> [192.0.2.1]:443",
                t + "(TCP connection): TGT -> TYPED",
                "1.5000:          Flow 2 (FREE): TYPED -> FREE",
            ]
        )
        self.assertEqual(out, ["flow=2 fail proto=tcp dir=out dst=192.0.2.1:443 src=198.51.100.7:5000 t=1.500"])

    def test_open_flows_closed_at_session_end(self):
        t = "1.0000:          Flow 0 "
        out = condense(
            [
                t + "(NEW): FREE -> NEW",
                t + "(TGT):     TAP [198.51.100.7]:5000 -> [192.0.2.1]:443 => HOST [0.0.0.0]:0 -> [192.0.2.1]:443",
                t + "(TCP connection): TGT -> TYPED",
                t + "(TCP connection): TYPED -> ACTIVE",
                "9.0000:          Flow 1 (NEW): FREE -> NEW",
                "event=end session=x",
            ]
        )
        self.assertEqual(
            out[-2], "flow=0 close proto=tcp dir=out dst=192.0.2.1:443 t=9.000 secs=8.000 reason=session-end"
        )
        self.assertEqual(out[-1], "event=end session=x")


class RecordPrefixTest(unittest.TestCase):
    def test_session_and_user(self):
        self.assertEqual(netlog.record_prefix("0123456789ab", "alice"), "session=0123456789ab user=alice ")

    def test_missing_parts_are_left_out(self):
        self.assertEqual(netlog.record_prefix("0123456789ab", ""), "session=0123456789ab ")
        self.assertEqual(netlog.record_prefix("", "alice"), "user=alice ")
        self.assertEqual(netlog.record_prefix("", ""), "")

    def test_user_cannot_forge_fields(self):
        p = netlog.record_prefix("s", 'bob dns domain=x"\nevent=end')
        self.assertEqual(len(p.splitlines()), 1)
        self.assertTrue(p.startswith('session=s user="bob dns'), p)
        self.assertTrue(p.endswith('" '), p)
        self.assertNotIn("\n", p)


class CondenseCommandTest(unittest.TestCase):
    """The condense command as the launcher runs it, reading standard input."""

    def run_condense(self, *extra):
        import subprocess
        import tempfile

        lines = [
            "1.0000:          Flow 0 (NEW): FREE -> NEW",
            "1.0001:          Flow 0 (TGT):     TAP [198.51.100.7]:5000 -> [192.0.2.1]:443 => HOST [0.0.0.0]:0 -> [192.0.2.1]:443",
            "1.0002:          Flow 0 (TCP connection): TGT -> TYPED",
            "1.0003:          Flow 0 (TCP connection): TYPED -> ACTIVE",
            "2.0000:          Flow 0 (FREE): ACTIVE -> FREE",
            "bwrap-dns domain=github.com type=A proto=udp rcode=NOERROR answers=192.0.2.1",
            "event=end session=abc user=alice",
        ]
        cmd = [sys.executable, os.path.join(HERE, "..", "lib", "bwrap_netlog.py"), "condense", "--session", "abc"]
        # The log tool's own output is discarded, so it writes to a file.
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "log")
            cmd += list(extra) + ["--", "tee", path]
            res = subprocess.run(
                cmd,
                input="\n".join(lines) + "\n",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            with open(path) as f:
                return f.read().splitlines()

    def test_every_record_names_session_and_user(self):
        out = self.run_condense("--user", "alice")
        records = [x for x in out if not x.startswith("event=")]
        self.assertGreaterEqual(len(records), 3)
        for line in records:
            self.assertTrue(line.startswith("session=abc user=alice "), line)
        self.assertEqual(out[-1], "event=end session=abc user=alice")

    def test_without_user_the_prefix_is_the_session_only(self):
        records = [x for x in self.run_condense() if not x.startswith("event=")]
        self.assertGreaterEqual(len(records), 3)
        for line in self.run_condense():
            if not line.startswith("event="):
                self.assertTrue(line.startswith("session=abc "), line)
                self.assertNotIn("user=", line)


class BridgeStderrTest(unittest.TestCase):
    def test_bytes_are_forwarded_at_once_and_unchanged(self):
        class Err(object):
            def __init__(self):
                self.buffer = io.BytesIO()

            def flush(self):
                pass

            def write(self, text):
                raise AssertionError("text written, bytes expected")

        err = Err()
        stop = threading.Event()
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "stderr")
            os.mkfifo(path)
            with mock.patch.object(sys, "stderr", err):
                t = threading.Thread(target=netlog._bridge_stderr, args=(path, stop))
                t.daemon = True
                t.start()
                fd = None
                for _ in range(100):  # the reader opens its end first; ENXIO until then
                    try:
                        fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
                        break
                    except OSError:
                        time.sleep(0.05)
                self.assertIsNotNone(fd, "the bridge never opened the FIFO")
                try:
                    # A prompt with no newline, and bytes that are not UTF-8.
                    os.write(fd, b"password: \xff\xfe")
                    for _ in range(60):
                        if err.buffer.getvalue():
                            break
                        time.sleep(0.05)
                    self.assertEqual(err.buffer.getvalue(), b"password: \xff\xfe")
                finally:
                    os.close(fd)
                    stop.set()
                    t.join(timeout=5)
        self.assertFalse(t.is_alive())


class BoundedSinkTest(unittest.TestCase):
    def test_a_sink_that_never_reads_does_not_block_and_drops(self):
        r, w = os.pipe()
        out = os.fdopen(w, "wb", 0)
        sink = netlog.BoundedSink(out, limit=10000, note=lambda n: b"dropped %d\n" % n)

        def feed():
            # Far more than the pipe (64 KiB) and the limit hold (20000 x 101
            # bytes), with pauses so the writer thread gets to fill the pipe.
            for i in range(20000):
                sink.put(b"x" * 100 + b"\n")
                if i % 50 == 0:
                    time.sleep(0.002)

        feeder = threading.Thread(target=feed)
        feeder.daemon = True
        try:
            feeder.start()
            feeder.join(30)  # a put() that blocked would never finish
            self.assertFalse(feeder.is_alive(), "put() blocked on a sink that does not read")
            self.assertGreater(sink.dropped, 0)
            self.assertGreater(sink.size, 9000)  # full, to within one record
            self.assertFalse(sink.close(0.2))  # still stalled: reported, not waited out
        finally:
            os.close(r)  # the blocked write now fails, and the rest is dropped
        try:
            self.assertTrue(sink.close(5))
            self.assertTrue(sink.dead)
        finally:
            out.close()

    def test_everything_is_written_when_the_sink_reads(self):
        out = io.BytesIO()
        sink = netlog.BoundedSink(out)
        for i in range(100):
            sink.put(b"line %d\n" % i)
        self.assertTrue(sink.close(5))
        self.assertEqual(out.getvalue().splitlines()[0], b"line 0")
        self.assertEqual(len(out.getvalue().splitlines()), 100)

    def test_a_burst_to_a_healthy_sink_loses_nothing(self):
        out = io.BytesIO()
        sink = netlog.BoundedSink(out)
        for i in range(50000):
            self.assertTrue(sink.put(b"line %d\n" % i))
        self.assertTrue(sink.close(10))
        self.assertEqual(len(out.getvalue().splitlines()), 50000)
        self.assertEqual(sink.dropped, 0)

    def test_a_note_says_how_many_were_lost(self):
        gate = threading.Event()

        class Slow(object):
            def __init__(self):
                self.data = b""

            def write(self, data):
                gate.wait(5)
                self.data += bytes(data)
                return len(data)

            def flush(self):
                pass

        out = Slow()
        sink = netlog.BoundedSink(out, limit=4, note=lambda n: b"lost %d\n" % n)
        self.assertTrue(sink.put(b"a\n"))  # the writer takes this and blocks
        for _ in range(100):
            if not sink.items:
                break
            time.sleep(0.02)
        results = [sink.put(b"b\n") for _ in range(10)]
        self.assertIn(False, results)
        lost = sink.dropped
        self.assertGreater(lost, 0)
        gate.set()
        for _ in range(100):  # the writer drains what is waiting
            if not sink.items:
                break
            time.sleep(0.05)
        self.assertTrue(sink.put(b"z\n", wait=2))
        self.assertTrue(sink.close(5))
        self.assertIn(b"lost %d\nz\n" % lost, out.data)  # the note and the record are one item
        self.assertEqual(sink.dropped, 0)

    def test_a_record_waits_for_room_when_asked_to(self):
        gate = threading.Event()

        class Slow(object):
            def write(self, data):
                gate.wait(5)
                return len(data)

            def flush(self):
                pass

        sink = netlog.BoundedSink(Slow(), limit=4)
        self.assertTrue(sink.put(b"a\n"))
        for _ in range(100):
            if not sink.items:
                break
            time.sleep(0.02)
        self.assertTrue(sink.put(b"bb\n"))
        self.assertFalse(sink.put(b"cc\n"))  # no room, no waiting
        threading.Timer(0.3, gate.set).start()
        self.assertTrue(sink.put(b"dd\n", wait=5))  # room once the writer takes the first
        self.assertTrue(sink.close(5))


class StalledLogToolTest(unittest.TestCase):
    """condense with a log tool that stays alive but stops reading."""

    LIB = os.path.join(HERE, "..", "lib")

    def run_condense(self, lines, args, wait=None, limit=None, stderr=subprocess.PIPE):
        script = "import sys; sys.path.insert(0, %r); import bwrap_netlog as n; %s%sn.condense(sys.argv[1:])" % (
            self.LIB,
            "n.SINK_CLOSE_WAIT = %d; " % wait if wait else "",
            "n.SINK_BYTES = %d; " % limit if limit else "",
        )
        return subprocess.run(
            [sys.executable, "-c", script, "--session", "abc"] + args,
            input=lines.encode(),
            stdout=subprocess.PIPE,
            stderr=stderr,
            timeout=60,
        )

    @staticmethod
    def dns_lines(n):
        return "".join(
            "bwrap-dns domain=host%d.example.org type=A proto=udp rcode=NOERROR answers=192.0.2.1\n" % i
            for i in range(n)
        )

    def test_condense_finishes_and_kills_the_tool(self):
        with tempfile.TemporaryDirectory() as d:
            pidfile = os.path.join(d, "pid")
            # Never reads its standard input: the pipe fills, and the old code
            # blocked in write() and stopped reading its own input.
            tool = ["sh", "-c", "echo $$ > %s; exec sleep 120" % pidfile]
            res = self.run_condense(
                self.dns_lines(30000), ["--end-record", "event=end session=abc", "--"] + tool, wait=1, limit=100000
            )
            self.assertEqual(res.returncode, 0, res.stderr.decode())
            self.assertIn(b"the log tool stopped reading", res.stderr)
            self.assertIn(b"the end record may be missing", res.stderr)
            self.assertRegex(res.stderr.decode(), r"reading; [1-9][0-9]* record\(s\) dropped")
            with open(pidfile) as f:
                pid = int(f.read())
            with self.assertRaises(OSError):  # killed and reaped
                os.kill(pid, 0)

    def test_a_closed_stderr_does_not_stop_the_cleanup(self):
        # The report that the tool stopped reading goes to stderr.  With stderr
        # closed (a terminal that has gone, a pipe whose reader has exited) the
        # write fails; the session directory must still be removed and the exit
        # status stay 0.
        with tempfile.TemporaryDirectory() as d:
            session_dir = os.path.join(d, "session")
            os.mkdir(session_dir)
            open(os.path.join(session_dir, "leftover"), "w").close()
            pidfile = os.path.join(d, "pid")
            tool = ["sh", "-c", "echo $$ > %s; exec sleep 120" % pidfile]
            r, w = os.pipe()
            os.close(r)  # nobody reads: a write to w raises EPIPE
            try:
                res = self.run_condense(
                    self.dns_lines(30000),
                    ["--end-record", "event=end session=abc", "--session-dir", session_dir, "--"] + tool,
                    wait=1,
                    limit=100000,
                    stderr=w,
                )
            finally:
                os.close(w)
            self.assertEqual(res.returncode, 0)
            self.assertFalse(os.path.exists(session_dir), "the session directory was left behind")
            with open(pidfile) as f:
                pid = int(f.read())
            with self.assertRaises(OSError):  # the tool was killed and reaped
                os.kill(pid, 0)

    def test_a_healthy_tool_gets_every_record_and_the_end_record(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "out")
            res = self.run_condense(self.dns_lines(20000), ["--end-record", "event=end session=abc", "--", "tee", out])
            self.assertEqual(res.returncode, 0, res.stderr.decode())
            with open(out) as f:
                got = f.read().splitlines()
        self.assertEqual(res.stderr, b"")
        self.assertEqual(len(got), 20001)
        self.assertEqual(
            got[0], "session=abc dns domain=host0.example.org type=A proto=udp rcode=NOERROR answers=192.0.2.1"
        )
        self.assertEqual(got[-1], "event=end session=abc")

    def test_without_a_tool_records_go_to_standard_output(self):
        res = self.run_condense(self.dns_lines(5000), [])
        self.assertEqual(res.returncode, 0, res.stderr.decode())
        self.assertEqual(len(res.stdout.splitlines()), 5000)


class DnsParseTest(unittest.TestCase):
    def test_query(self):
        self.assertEqual(netlog.parse_query(query("WWW.Example.org", 28)), ("www.example.org", "AAAA"))

    def test_answers_with_compression(self):
        self.assertEqual(
            netlog.parse_answers(answer(query("www.example.org"))), ("NOERROR", ["example.org", "192.0.2.10"])
        )

    def test_garbage(self):
        for bad in (b"", b"\x00" * 11, b"\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\xc0"):
            with self.assertRaises((ValueError, struct.error, IndexError)):
                netlog.parse_query(bad)

    def test_logfmt_control_characters(self):
        self.assertEqual(netlog._value("bad\nname\r\x1b"), "bad\\x0aname\\x0d\\x1b")


class DnsRelayTest(unittest.TestCase):
    def setUp(self):
        self.stop = threading.Event()
        self.up_udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.up_udp.bind(("127.0.0.1", 0))
        self.up_udp.settimeout(0.2)
        port = self.up_udp.getsockname()[1]
        self.up_tcp = socket.socket()
        self.up_tcp.bind(("127.0.0.1", port))
        self.up_tcp.listen()
        self.up_tcp.settimeout(0.2)
        self.up_tcp_answers = True
        self.up_udp_thread = threading.Thread(target=self._serve_udp)
        self.up_tcp_thread = threading.Thread(target=self._serve_tcp)
        self.up_udp_thread.start()
        self.up_tcp_thread.start()
        self.out = io.StringIO()
        self.relay = netlog.DnsRelay("127.0.0.1:0", "127.0.0.1:%d" % port, self.out)
        self.relay.listen = ("127.0.0.1", 0)
        self._open(self.relay)
        self.addr = self.relay.udp.getsockname()
        self.relay_thread = threading.Thread(target=self.relay.serve)
        self.relay_thread.start()

    def _open(self, relay):
        relay.bind()

    def tearDown(self):
        self.stop.set()
        self.relay.close()
        self.relay_thread.join(timeout=3)
        self.up_udp.close()
        self.up_tcp.close()
        self.up_udp_thread.join(timeout=3)
        self.up_tcp_thread.join(timeout=3)

    def _serve_udp(self):
        while not self.stop.is_set():
            try:
                q, a = self.up_udp.recvfrom(4096)
                self.up_udp.sendto(answer(q), a)
            except socket.timeout:
                continue
            except OSError:
                break

    def _serve_tcp(self):
        while not self.stop.is_set():
            try:
                c, _ = self.up_tcp.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with c:
                c.settimeout(1)
                if not self.up_tcp_answers:
                    continue  # accept and close: the lookup fails upstream
                try:
                    n = struct.unpack("!H", c.recv(2))[0]
                    r = answer(c.recv(n))
                    c.sendall(struct.pack("!H", len(r)) + r)
                except (OSError, struct.error):
                    pass

    def wait_lines(self, n):
        for _ in range(50):
            if len(self.out.getvalue().splitlines()) >= n:
                break
            time.sleep(0.05)
        return self.out.getvalue().splitlines()

    def test_udp(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as c:
            c.settimeout(3)
            c.sendto(query("www.example.org"), self.addr)
            self.assertEqual(netlog.parse_answers(c.recv(4096))[1], ["example.org", "192.0.2.10"])
        self.assertEqual(
            self.wait_lines(1),
            ["bwrap-dns domain=www.example.org type=A proto=udp rcode=NOERROR answers=192.0.2.10 cname=example.org"],
        )

    def test_tcp(self):
        with socket.create_connection(self.addr, timeout=3) as c:
            c.settimeout(3)
            for _ in range(2):
                q = query("www.example.org", 28)
                c.sendall(struct.pack("!H", len(q)) + q)
                n = struct.unpack("!H", c.recv(2))[0]
                self.assertEqual(len(c.recv(n)), n)
        self.assertIn("type=AAAA proto=tcp rcode=NOERROR", self.wait_lines(1)[0])
        self.assertEqual(len(self.wait_lines(2)), 2)

    def test_tcp_query_that_fails_upstream_is_logged_once(self):
        self.up_tcp_answers = False
        with socket.create_connection(self.addr, timeout=3) as c:
            c.settimeout(3)
            q = query("www.example.org")
            c.sendall(struct.pack("!H", len(q)) + q)
            try:
                answer = c.recv(2)
            except ConnectionResetError:  # a reset is as good as a close here
                answer = b""
            self.assertEqual(answer, b"")  # let go without an answer
        self.wait_lines(1)
        time.sleep(0.3)  # a second record, if there were one, would be here by now
        self.assertEqual(
            self.out.getvalue().splitlines(),
            ["bwrap-dns domain=www.example.org type=A proto=tcp rcode=TIMEOUT answers=-"],
        )

    def test_tcp_message_shorter_than_a_dns_header_is_dropped_unlogged(self):
        with socket.create_connection(self.addr, timeout=3) as c:
            c.settimeout(3)
            c.sendall(struct.pack("!H", 0))  # a zero-length query
            self.assertEqual(c.recv(2), b"")
        time.sleep(0.3)
        self.assertEqual(self.out.getvalue(), "")

    def test_tcp_client_that_closes_without_a_query_is_not_logged(self):
        with socket.create_connection(self.addr, timeout=3):
            pass
        with socket.create_connection(self.addr, timeout=3) as c:
            q = query("www.example.org")
            c.sendall(struct.pack("!H", len(q)) + q[:5])  # closes in the middle of one
        time.sleep(0.5)
        self.assertEqual(self.out.getvalue(), "")

    def test_dns_name_does_not_forge_log_lines(self):
        q = query("bad\nname.example.org")
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as c:
            c.settimeout(3)
            c.sendto(q, self.addr)
            c.recv(4096)
        lines = self.wait_lines(1)
        self.assertEqual(len(lines), 1)
        self.assertIn("domain=bad\\x0aname.example.org", lines[0])

    def test_cname_does_not_forge_log_lines(self):
        q = query("www.example.org")
        r = answer(q).replace(b"\x07example\x03org", b"\x07xx:\nabc\x03org")
        self.relay.log(q, r, "udp")
        self.assertEqual(len(self.out.getvalue().splitlines()), 1)
        self.assertIn("cname=xx:\\x0aabc.org", self.out.getvalue())

    def test_overload_is_bounded_and_fails_fast(self):
        gate = threading.Event()
        relay = netlog.DnsRelay("127.0.0.1:0", "127.0.0.1:53", workers=1, pending=1)
        before = len([t for t in threading.enumerate() if t.name.startswith("bwrap-dns")])
        try:
            self.assertTrue(relay._submit(gate.wait, 2))
            self.assertTrue(relay._submit(gate.wait, 2))
            self.assertFalse(relay._submit(gate.wait, 2))
            after = len([t for t in threading.enumerate() if t.name.startswith("bwrap-dns")])
            self.assertLessEqual(after - before, 1)
        finally:
            gate.set()
            relay.close()

    def test_overload_returns_servfail(self):
        gate = threading.Event()
        relay = netlog.DnsRelay("127.0.0.1:0", "%s:%d" % self.relay.upstream, io.StringIO(), workers=1, pending=0)
        relay.bind()
        serve_thread = threading.Thread(target=relay.serve)
        serve_thread.start()
        try:
            self.assertTrue(relay._submit(gate.wait, 2))
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as c:
                c.settimeout(3)
                c.sendto(query("www.example.org"), relay.udp.getsockname())
                self.assertEqual(netlog.parse_answers(c.recv(4096))[0], "SERVFAIL")
        finally:
            gate.set()
            relay.close()
            serve_thread.join(timeout=3)


class DnsRelayAdoptTest(DnsRelayTest):
    """Every DnsRelayTest case again, against pre-bound sockets.

    With slirp4netns the relay cannot bind for itself: the namespace maps the
    real uid, so the execve that starts the relay clears its capabilities and
    port 53 is out of reach.  The process that creates the namespace binds
    first and passes the descriptors (_NET_NS_IDENTITY in
    bwrap_sandbox_lib.sh), which DnsRelay.adopt takes over.
    """

    def _open(self, relay):
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.bind(("127.0.0.1", 0))
        tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        tcp.bind(udp.getsockname())
        tcp.listen(16)
        # Duplicate and close, as inheriting across the launcher's exec does.
        udp_fd, tcp_fd = os.dup(udp.fileno()), os.dup(tcp.fileno())
        udp.close()
        tcp.close()
        relay.adopt(udp_fd, tcp_fd)
        self.assertEqual(relay.listen, relay.udp.getsockname())


if __name__ == "__main__":
    unittest.main()
