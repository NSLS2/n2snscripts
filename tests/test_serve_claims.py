"""Tests for bwopencode2's --serve port claims (serve_choose_port).

    python3 -m unittest discover -s tests -p 'test_*.py'

Each launch claims a port from a small range with a file in the state directory.
Two launches that start at the same moment and both see a stale claim file (left
by a launcher that has gone) must not end up with the same port.  The launches
here are separate bash processes that source bin/bwopencode2, wait at a gate
until all are ready, choose a port together and then stay alive (a claim belongs
to a running launcher, so a launch that has exited no longer holds its port).
"""

import os
import select
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
WRAPPER = os.path.join(HERE, "..", "bin", "bwopencode2")

LAUNCH = r"""
set -euo pipefail
source "$1"
_HOME="$2"
_PWD="$2"
DRY_RUN=0
NET_SHARE=1
SERVE_ADDR=127.0.0.1
SERVE_PORT_REQUEST=""
SERVE_PORT_LO="$3"
SERVE_PORT_HI="$4"
# What is tested is the claim, not whether the host has the port free: another
# program binding a port in the range must not fail these tests.
serve_port_is_free() { return 0; }
echo ready
read -r _go
serve_choose_port
echo "PORT=${SERVE_PORT}"
echo "FD=${SERVE_CLAIMS_FD}"
read -r _end || true
"""


_NEXT = [30000 + (os.getpid() * 7) % 20000]


def free_range(count):
    """COUNT consecutive port numbers for a test; a new range each call, so
    claims left by one test never meet another's."""
    base = _NEXT[0]
    _NEXT[0] += count + 1
    return base


def stale_pid():
    """A pid that is certainly not running: a child that has been reaped."""
    child = subprocess.Popen([sys.executable, "-c", "pass"])
    child.wait()
    return child.pid


class ServeClaimsTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="serve-claims-test.")
        self.state = os.path.join(self.home, ".local", "state", "bwopencode2", "serve")
        self.procs = []

    def reap(self):
        for p in self.procs:
            try:
                p.stdin.close()
            except OSError:
                pass
            p.kill()
            p.wait()
            p.stdout.close()
        self.procs = []

    def tearDown(self):
        self.reap()
        shutil.rmtree(self.home, ignore_errors=True)

    def seed_stale(self, lo, hi):
        os.makedirs(self.state, mode=0o700, exist_ok=True)
        pid = stale_pid()
        for port in range(lo, hi + 1):
            with open(os.path.join(self.state, "%d.session" % port), "w") as f:
                f.write("pid=%d\nstart=1\nport=%d\n" % (pid, port))

    def launch(self, lo, hi):
        p = subprocess.Popen(
            ["bash", "-c", LAUNCH, "_", WRAPPER, self.home, str(lo), str(hi)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            universal_newlines=True,
        )
        self.procs.append(p)
        self.assertEqual(p.stdout.readline().strip(), "ready")
        return p

    def choose_together(self, count, lo, hi):
        procs = [self.launch(lo, hi) for _ in range(count)]
        for p in procs:  # the gate: all choose at (nearly) the same moment
            p.stdin.write("go\n")
        for p in procs:
            p.stdin.flush()
        ports, fds = [], []
        for p in procs:
            port = p.stdout.readline().strip()
            fd = p.stdout.readline().strip()
            self.assertTrue(port.startswith("PORT="), "no port chosen: %r" % port)
            ports.append(int(port[5:]))
            fds.append(fd)
        return ports, fds

    def test_launches_that_start_together_get_different_ports(self):
        count = 6
        for _ in range(8):  # the race is a matter of timing: try it repeatedly
            lo = free_range(count)
            shutil.rmtree(self.state, ignore_errors=True)
            self.seed_stale(lo, lo + count - 1)
            ports, _ = self.choose_together(count, lo, lo + count - 1)
            self.assertEqual(sorted(ports), list(range(lo, lo + count)), "two launches got the same port: %r" % ports)
            self.reap()

    def test_a_running_launch_keeps_its_port(self):
        lo = free_range(3)
        first = self.launch(lo, lo + 2)
        first.stdin.write("go\n")
        first.stdin.flush()
        self.assertEqual(first.stdout.readline().strip(), "PORT=%d" % lo)
        second = self.launch(lo, lo + 2)
        second.stdin.write("go\n")
        second.stdin.flush()
        self.assertEqual(second.stdout.readline().strip(), "PORT=%d" % (lo + 1))

    def test_the_lock_is_released_once_a_port_is_chosen(self):
        lo = free_range(2)
        first = self.launch(lo, lo + 1)
        first.stdin.write("go\n")
        first.stdin.flush()
        first.stdout.readline()
        self.assertEqual(first.stdout.readline().strip(), "FD=", "the claims lock is still open after the choice")
        # So another launch is not held up by it.
        second = self.launch(lo, lo + 1)
        second.stdin.write("go\n")
        second.stdin.flush()
        self.assertEqual(second.stdout.readline().strip(), "PORT=%d" % (lo + 1))

    @unittest.skipUnless(shutil.which("flock"), "flock (util-linux) not installed")
    def test_a_launch_waits_for_the_lock_instead_of_racing(self):
        lo = free_range(2)
        os.makedirs(self.state, mode=0o700, exist_ok=True)
        lockfile = os.path.join(self.state, "claims.lock")
        # Holds the lock until its stdin is closed: an explicit release, not a timeout.
        holder = subprocess.Popen(
            ["flock", "-x", lockfile, "sh", "-c", "echo held; read x"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            universal_newlines=True,
        )

        def release():
            for stream in (holder.stdin, holder.stdout):
                try:
                    stream.close()
                except OSError:
                    pass
            holder.kill()
            holder.wait()

        self.addCleanup(release)
        self.assertEqual(holder.stdout.readline().strip(), "held")
        p = self.launch(lo, lo + 1)
        p.stdin.write("go\n")
        p.stdin.flush()
        # While the lock is held the launch cannot finish choosing.
        ready, _, _ = select.select([p.stdout], [], [], 1.5)
        self.assertEqual(ready, [], "the launch chose a port while the lock was held")
        holder.stdin.close()  # release it
        ready, _, _ = select.select([p.stdout], [], [], 20)
        self.assertEqual(ready, [p.stdout], "the launch did not go on after the lock was released")
        self.assertEqual(p.stdout.readline().strip(), "PORT=%d" % lo)


if __name__ == "__main__":
    sys.exit(unittest.main())
