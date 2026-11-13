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
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "lib", "bwrap_sandbox_lib.sh")


_SNIPPET = None


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


if __name__ == "__main__":
    unittest.main()
