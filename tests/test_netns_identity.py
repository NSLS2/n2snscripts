"""Tests for _NET_NS_IDENTITY in lib/bwrap_sandbox_lib.sh.

    python3 -m unittest discover -s tests -p 'test_*.py'

The snippet replaces `unshare --user --map-root-user --net` for the
slirp4netns backend: it unshares a user and a network namespace, maps the
real uid and gid to themselves and execs its arguments in the same process.
The identity map matters because bubblewrap 0.4.0 (RHEL 8) cannot start under
a namespace that maps only uid 0 -- it calls setuid() on an unmapped id and
dies with "unable to drop root uid: Invalid argument".

The snippet is read out of the shell library rather than copied, so the tests
fail if the two drift apart.
"""

import os
import socket
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "lib", "bwrap_sandbox_lib.sh")


INSPECT = """
import fcntl, socket, struct, sys
SIOCGIFFLAGS, IFF_UP = 0x8913, 0x1
udp_fd, tcp_fd = int(sys.argv[1]), int(sys.argv[2])
c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
flags = struct.unpack('16sh22x', fcntl.ioctl(c, SIOCGIFFLAGS, struct.pack('16sh22x', b'lo', 0)))[1]
u = socket.fromfd(udp_fd, socket.AF_INET, socket.SOCK_DGRAM)
t = socket.fromfd(tcp_fd, socket.AF_INET, socket.SOCK_STREAM)
print('lo_up=%d' % bool(flags & IFF_UP))
print('udp=%s:%d' % u.getsockname())
print('tcp=%s:%d' % t.getsockname())
print('udp_type=%d' % u.type)
print('listening=%d' % t.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN))
"""

_SNIPPET = None


def shell_var(name):
    """Read a plain variable out of the shell library."""
    out = subprocess.run(
        ["bash", "-c", 'source "$1" 2>/dev/null; printf "%%s" "${%s}"' % name, "_", LIB],
        stdout=subprocess.PIPE,
        check=True,
    )
    return out.stdout.decode()


def snippet():
    """The value of _NET_NS_IDENTITY, as the launcher would pass it."""
    global _SNIPPET
    if _SNIPPET is None:
        out = subprocess.run(
            ["bash", "-c", 'source "$1" 2>/dev/null; printf "%s" "${_NET_NS_IDENTITY}"', "_", LIB],
            stdout=subprocess.PIPE,
            check=True,
        )
        _SNIPPET = out.stdout.decode()
    return _SNIPPET


def run(*args):
    """Run the snippet with ARGS as the command it execs."""
    return subprocess.run(
        [sys.executable, "-I", "-c", snippet(), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )


def userns_available():
    probe = run("/bin/true")
    return probe.returncode == 0


class NetNsIdentityTests(unittest.TestCase):
    def test_snippet_is_defined(self):
        self.assertIn("CLONE_NEWUSER", snippet())
        self.assertIn("execvp", snippet())

    def test_reads_ids_before_unshare(self):
        """A map naming the post-unshare overflow id is refused with EPERM."""
        text = snippet()
        self.assertLess(
            text.index("os.getuid()"),
            text.index("libc.unshare"),
            "the real ids must be read before the unshare",
        )


@unittest.skipUnless(userns_available(), "unprivileged user namespaces are unavailable")
class NetNsIdentityRunTests(unittest.TestCase):
    def read(self, path):
        got = run("/bin/cat", path)
        self.assertEqual(got.returncode, 0, got.stderr.decode())
        return got.stdout.decode().split()

    def test_uid_map_is_identity(self):
        inside, outside, count = self.read("/proc/self/uid_map")
        self.assertEqual(inside, outside)
        self.assertEqual(int(outside), os.getuid())
        self.assertEqual(count, "1")

    def test_gid_map_is_identity(self):
        inside, outside, count = self.read("/proc/self/gid_map")
        self.assertEqual(inside, outside)
        self.assertEqual(int(outside), os.getgid())
        self.assertEqual(count, "1")

    def test_setgroups_is_denied(self):
        self.assertEqual(self.read("/proc/self/setgroups"), ["deny"])

    def test_keeps_the_real_uid(self):
        got = run("/usr/bin/id", "-u")
        self.assertEqual(got.stdout.decode().strip(), str(os.getuid()))

    def test_network_namespace_is_new(self):
        got = run("/bin/readlink", "/proc/self/ns/net")
        self.assertNotEqual(got.stdout.decode().strip(), os.readlink("/proc/self/ns/net"))

    def test_does_not_fork(self):
        """slirp4netns is pointed at the launcher's pid, which must not change."""
        got = run("/bin/sh", "-c", "echo $PPID")
        self.assertEqual(got.stdout.decode().strip(), str(os.getpid()))

    def test_failure_to_exec_is_reported(self):
        got = run("/nonexistent/command")
        self.assertNotEqual(got.returncode, 0)


@unittest.skipUnless(userns_available(), "unprivileged user namespaces are unavailable")
class NetNsIdentityDnsTests(unittest.TestCase):
    """The --dns pre-bind, which the DNS relay depends on under slirp4netns.

    The relay is started after two execs and the namespace maps the real uid,
    so it holds no capabilities and cannot bind port 53 or raise loopback.
    The mapper does both while it still can, between the unshare and the exec.
    """

    def setUp(self):
        self.addr = shell_var("_NET_DNS_RELAY_ADDR")
        self.port = shell_var("_NET_DNS_RELAY_PORT")
        self.udp_fd = shell_var("_NET_FD_DNS_UDP")
        self.tcp_fd = shell_var("_NET_FD_DNS_TCP")

    def fields(self, *extra):
        got = run(
            "--dns",
            self.addr,
            self.port,
            self.udp_fd,
            self.tcp_fd,
            "--",
            sys.executable,
            "-c",
            INSPECT,
            self.udp_fd,
            self.tcp_fd,
            *extra,
        )
        self.assertEqual(got.returncode, 0, got.stderr.decode())
        return dict(line.split("=", 1) for line in got.stdout.decode().split())

    def test_descriptors_are_bound_to_the_relay_address(self):
        f = self.fields()
        self.assertEqual(f["udp"], "%s:%s" % (self.addr, self.port))
        self.assertEqual(f["tcp"], "%s:%s" % (self.addr, self.port))

    def test_loopback_is_up(self):
        """A fresh network namespace has lo down, so :53 could not be bound."""
        self.assertEqual(self.fields()["lo_up"], "1")

    def test_tcp_socket_is_listening(self):
        self.assertEqual(self.fields()["listening"], "1")

    def test_udp_socket_is_a_datagram_socket(self):
        self.assertEqual(int(self.fields()["udp_type"]), int(socket.SOCK_DGRAM))

    def test_without_dns_the_descriptors_are_absent(self):
        got = run(sys.executable, "-c", INSPECT, self.udp_fd, self.tcp_fd)
        self.assertNotEqual(got.returncode, 0)
        self.assertIn("Bad file descriptor", got.stderr.decode())

    def test_a_bad_address_fails_the_launch(self):
        got = run("--dns", "203.0.113.9", self.port, self.udp_fd, self.tcp_fd, "--", "/bin/true")
        self.assertNotEqual(got.returncode, 0)
        self.assertIn("DNS relay sockets", got.stderr.decode())


if __name__ == "__main__":
    unittest.main()
