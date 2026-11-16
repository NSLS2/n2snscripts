"""Tests for the descriptor holder in lib/bwrap_sandbox_lib.sh (_net_hold_start).

    python3 -m unittest discover -s tests -p 'test_*.py'

With a private network the launcher ends in an `exec` into pasta (or the
slirp4netns identity mapper), and pasta closes every descriptor it inherited
from 3 up.  The database guard's session lock (bwopencode2) is a descriptor of
the launcher, and a flock lasts only as long as some process holds it, so the
lock would be released while OpenCode runs.  net_hold_fd registers such a
descriptor and _net_hold_start keeps it open in a background holder until the
launcher process is gone.

The stand-in for pasta here is a process that closes every descriptor from 3
up, as pasta does, and then stays alive.  The checks are made from outside,
with flock on the lock file, as another host's guard would.
"""

import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "lib", "bwrap_sandbox_lib.sh")

# $1 library, $2 lock file, $3 seconds the stand-in lives, $4 a descriptor the
# test passed in (the write end of a pipe), $5 hold (yes) or not, $6 backend,
# $7 the python to run the stand-in with, $8 a file the stand-in creates once it
# has closed its descriptors.
DRIVER = r"""
source "$1" 2>/dev/null
exec {fd}<> "$2"
flock -s -n "${fd}" || exit 90
_NET_BACKEND="$6"
if [[ "$5" == yes ]]; then
    net_hold_fd "${fd}"
fi
_net_hold_start
exec "$7" -c 'import os, sys, time; os.closerange(3, 1024); open(sys.argv[2], "w").close(); time.sleep(float(sys.argv[1]))' "$3" "$8"
"""


def lock_is_held(path):
    """True while another process holds a lock that excludes an exclusive one."""
    return subprocess.run(["flock", "-x", "-n", path, "true"]).returncode != 0


def wait_for(condition, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if condition():
            return True
        time.sleep(0.1)
    return condition()


def process_gone(pid):
    """True when PID no longer exists, or is a zombie nobody has reaped yet."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            return f.read().rsplit(")", 1)[1].split()[0] == "Z"
    except OSError:
        return True


def holder_ready(pid, keep):
    """The holder has closed every descriptor above 2 except KEEP's and ignores
    the session's signals (read from /proc, so nothing is guessed from time)."""
    try:
        fds = {int(n) for n in os.listdir("/proc/%d/fd" % pid)}
        with open("/proc/%d/status" % pid) as f:
            status = f.read()
    except OSError:
        return False
    ignored = int(next(ln for ln in status.splitlines() if ln.startswith("SigIgn:")).split()[1], 16)
    wanted = sum(
        1 << (sig - 1) for sig in (signal.SIGINT, signal.SIGQUIT, signal.SIGHUP, signal.SIGTERM, signal.SIGPIPE)
    )
    return {n for n in fds if n > 2} <= keep and ignored & wanted == wanted


def children_of(pid):
    out = []
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % name) as f:
                stat = f.read()
        except OSError:
            continue
        if int(stat.rsplit(")", 1)[1].split()[1]) == pid:
            out.append(int(name))
    return out


@unittest.skipUnless(shutil.which("flock"), "flock (util-linux) not installed")
class NetHoldTest(unittest.TestCase):
    LIFE = 6  # seconds the stand-in for pasta stays alive

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="net-hold-test.")
        self.lock = os.path.join(self.dir, "lock")
        open(self.lock, "w").close()
        self.ready = os.path.join(self.dir, "ready")
        self.read, self.write = os.pipe()
        self.proc = None
        self.holders = []

    def tearDown(self):
        if self.proc is not None:
            self.proc.kill()
            self.proc.wait()
        for pid in self.holders:  # a holder that did not end by itself
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        for fd in (self.read, self.write):
            try:
                os.close(fd)
            except OSError:
                pass
        if self.proc is not None and self.proc.stderr is not None:
            self.proc.stderr.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def start(self, hold="yes", backend="pasta"):
        self.proc = subprocess.Popen(
            [
                "bash",
                "-c",
                DRIVER,
                "_",
                LIB,
                self.lock,
                str(self.LIFE),
                str(self.write),
                hold,
                backend,
                sys.executable,
                self.ready,
            ],
            pass_fds=(self.write,),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        # The stand-in has closed its descriptors, as pasta does, once it has
        # made the file.  The holder was forked before that.
        self.assertTrue(wait_for(lambda: os.path.exists(self.ready), 10), self.stderr())
        os.close(self.write)  # the test keeps only the read end
        self.write = os.dup(self.read)  # something harmless for tearDown to close
        self.holders = children_of(self.proc.pid)
        if hold == "yes" and backend == "pasta":
            self.assertEqual(len(self.holders), 1, "expected one holder, found %r" % self.holders)
            lock_fd = self.lock_fd_of(self.holders[0])
            self.assertTrue(
                wait_for(lambda: holder_ready(self.holders[0], {lock_fd}), 10), "the holder did not finish starting"
            )

    def lock_fd_of(self, pid):
        """The descriptor of the holder that is the lock file."""
        for name in os.listdir("/proc/%d/fd" % pid):
            if int(name) > 2 and os.path.realpath("/proc/%d/fd/%s" % (pid, name)) == os.path.realpath(self.lock):
                return int(name)
        self.fail("the holder does not hold the lock file")

    def cmdline(self):
        try:
            with open("/proc/%d/cmdline" % self.proc.pid) as f:
                return f.read()
        except OSError:
            return ""

    def stderr(self):
        return "" if self.proc.poll() is None else self.proc.stderr.read().decode()

    def test_without_the_holder_the_lock_is_lost_at_the_exec(self):
        # The bug: the stand-in closes the descriptor, as pasta does.
        self.start(hold="no")
        self.assertTrue(wait_for(lambda: not lock_is_held(self.lock), 3), "the control did not lose the lock")
        self.assertIsNone(self.proc.poll(), "the stand-in ended early")

    def test_the_lock_stays_held_while_the_sandbox_runs(self):
        self.start()
        time.sleep(1.5)
        self.assertIsNone(self.proc.poll(), "the stand-in ended early")
        self.assertTrue(lock_is_held(self.lock), "the lock was released while the sandbox ran")

    def test_the_lock_is_released_soon_after_the_sandbox_ends(self):
        self.start()
        self.assertTrue(lock_is_held(self.lock))
        holder = self.holders[0]
        self.assertFalse(process_gone(holder))
        self.proc.wait(timeout=self.LIFE + 10)
        self.assertTrue(wait_for(lambda: not lock_is_held(self.lock), 5), "the holder outlived the sandbox")
        # Reparented once the launcher has gone, it is no longer a child of it.
        self.assertTrue(wait_for(lambda: process_gone(holder), 5), "the holder did not exit")

    def test_the_holder_keeps_nothing_else_open(self):
        # A descriptor of the launcher that is not registered, here the write
        # end of a pipe, must not stay open in the holder: slirp4netns, for
        # one, exits only when bwrap closes its sync descriptor.
        self.start()
        self.assertIsNone(self.proc.poll())
        self.assertTrue(lock_is_held(self.lock))
        os.set_blocking(self.read, False)
        try:
            data = os.read(self.read, 1)
        except BlockingIOError:
            self.fail("the pipe is still open: the holder kept a descriptor that was not registered")
        self.assertEqual(data, b"")  # end of file: every writer has gone

    def test_the_holder_ignores_the_signals_of_the_session(self):
        self.start()
        for sig in (signal.SIGINT, signal.SIGHUP, signal.SIGTERM, signal.SIGQUIT):
            os.kill(self.holders[0], sig)
        time.sleep(1.5)
        self.assertFalse(process_gone(self.holders[0]))
        self.assertIsNone(self.proc.poll())
        self.assertTrue(lock_is_held(self.lock), "a signal to the session took the lock")

    def test_nothing_is_started_without_a_private_network(self):
        # --share-net: no pasta, the descriptor goes through exec itself.
        self.start(backend="none")
        self.assertEqual(children_of(self.proc.pid), [])

    def test_nothing_is_started_when_nothing_is_registered(self):
        self.start(hold="no")
        self.assertEqual(children_of(self.proc.pid), [])

    def test_only_descriptors_above_two_are_accepted(self):
        script = 'source "$1" 2>/dev/null; net_hold_fd 0 1 2 x "" 7 12; printf "%s\\n" "${NET_HOLD_FDS[*]}"'
        out = subprocess.run(["bash", "-c", script, "_", LIB], stdout=subprocess.PIPE, timeout=30)
        self.assertEqual(out.stdout.decode().strip(), "7 12")


if __name__ == "__main__":
    sys.exit(unittest.main())
