"""Tests for lib/bwrap_netlog.py (the network log condenser and DNS relay).

    python3 -m unittest discover -s tests -p 'test_*.py'

tests/data/pasta-debug.log is part of a real pasta 2026_10_02 debug log
(--debug --log-file, with its stderr copy of the setup), addresses of the
host replaced with documentation addresses.
"""

import io
import os
import re
import socket
import struct
import sys
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import bwrap_netlog as netlog  # noqa: E402

FIXTURE = os.path.join(HERE, "data", "pasta-debug.log")


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

    def test_error_kept(self):
        self.assertIn('pasta level=error msg="Listening address not allowed for -T 127.0.42.1/3000" t=0.001', self.out)

    def test_header(self):
        self.assertEqual(self.out[0], "pasta version=2026_10_02.cba3570 pid=3962723")

    def test_names_from_dns(self):
        out = condense(["bwrap-dns name=github.com type=A proto=udp rcode=NOERROR answers=140.82.112.21"] + self.raw)
        self.assertEqual(out[0], "dns name=github.com type=A proto=udp rcode=NOERROR answers=140.82.112.21")
        line = next(x for x in out if " open " in x and "dst=140.82.112.21:443" in x)
        self.assertTrue(line.endswith("name=github.com t=0.917"), line)

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


class DnsRelayTest(unittest.TestCase):
    def setUp(self):
        self.up_udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.up_udp.bind(("127.0.0.1", 0))
        port = self.up_udp.getsockname()[1]
        self.up_tcp = socket.socket()
        self.up_tcp.bind(("127.0.0.1", port))
        self.up_tcp.listen()
        threading.Thread(target=self._serve_udp, daemon=True).start()
        threading.Thread(target=self._serve_tcp, daemon=True).start()
        self.out = io.StringIO()
        self.relay = netlog.DnsRelay("127.0.0.1:0", "127.0.0.1:%d" % port, self.out)
        self.relay.listen = ("127.0.0.1", 0)
        self.relay.bind()
        lport = self.relay.udp.getsockname()[1]
        self.relay.tcp.close()
        self.relay.tcp = socket.socket()
        self.relay.tcp.bind(("127.0.0.1", lport))
        self.relay.tcp.listen()
        self.addr = ("127.0.0.1", lport)
        threading.Thread(target=self.relay.serve, daemon=True).start()

    def _serve_udp(self):
        while True:
            q, a = self.up_udp.recvfrom(4096)
            self.up_udp.sendto(answer(q), a)

    def _serve_tcp(self):
        while True:
            c, _ = self.up_tcp.accept()
            n = struct.unpack("!H", c.recv(2))[0]
            r = answer(c.recv(n))
            c.sendall(struct.pack("!H", len(r)) + r)
            c.close()

    def wait_lines(self, n):
        for _ in range(50):
            if len(self.out.getvalue().splitlines()) >= n:
                break
            time.sleep(0.05)
        return self.out.getvalue().splitlines()

    def test_udp(self):
        c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        c.settimeout(3)
        c.sendto(query("www.example.org"), self.addr)
        self.assertEqual(netlog.parse_answers(c.recv(4096))[1], ["example.org", "192.0.2.10"])
        self.assertEqual(
            self.wait_lines(1),
            ["bwrap-dns name=www.example.org type=A proto=udp rcode=NOERROR answers=192.0.2.10 cname=example.org"],
        )

    def test_tcp(self):
        c = socket.create_connection(self.addr, timeout=3)
        q = query("www.example.org", 28)
        c.sendall(struct.pack("!H", len(q)) + q)
        n = struct.unpack("!H", c.recv(2))[0]
        self.assertEqual(len(c.recv(n)), n)
        self.assertIn("type=AAAA proto=tcp rcode=NOERROR", self.wait_lines(1)[0])


if __name__ == "__main__":
    unittest.main()
