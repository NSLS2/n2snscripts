"""Exercise bwopencode2 --serve's sign-in output and --serve-open without a real server.

The wrapper that runs inside the sandbox (SERVE_WRAPPER) is cut out of
bin/bwopencode2 and run with a fake OpenCode server.  The host-side helper
(serve_open_run) is run by sourcing bin/bwopencode2 with a stub browser.
"""

import os
import pty
import re
import select
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


WRAPPER = Path(__file__).resolve().parent.parent / "bin" / "bwopencode2"
PASSWORD = "test-only-password"

# GET gives 401 (the server is listening).  POST /api/pair checks the Basic
# password the launcher is meant to send on curl's stdin and gives a new code
# each time (code1, code2, ...).  FAKE_PAIR=fail answers 500 instead.
FAKE_SERVER = """#!/usr/bin/env python3
import base64
import http.server
import os
import sys
import threading

expected = "Basic " + base64.b64encode(("opencode:" + os.environ["OPENCODE_PASSWORD"]).encode()).decode()
count = [0]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(401)
        self.end_headers()

    def do_POST(self):
        if os.environ.get("FAKE_PAIR") == "fail":
            self.send_response(500)
            self.end_headers()
            return
        if self.headers.get("Authorization") != expected or self.path != "/api/pair":
            self.send_response(401)
            self.end_headers()
            return
        count[0] += 1
        body = ('{"code":"code%d"}' % count[0]).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

httpd = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[-1])), Handler)
httpd.daemon_threads = True
threading.Timer(60, httpd.shutdown).start()
httpd.serve_forever()
"""


def wrapper_source():
    match = re.search(
        r"read -r -d '' SERVE_WRAPPER << 'SERVE_WRAPPER_EOF' \|\| true\n(.*?)\nSERVE_WRAPPER_EOF",
        WRAPPER.read_text(),
        re.S,
    )
    assert match is not None
    return match.group(1)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Reader:
    """Read a process's stderr in pieces (select on a buffered file object misses data)."""

    def __init__(self, proc):
        self.fd = proc.stderr.fileno()
        self.buf = ""

    def until(self, text, timeout=12):
        """Return what was read up to the end of the line that holds text."""
        deadline = time.monotonic() + timeout
        while text not in self.buf or "\n" not in self.buf[self.buf.index(text) :]:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            ready, _, _ = select.select([self.fd], [], [], remaining)
            if not ready:
                break
            chunk = os.read(self.fd, 65536)
            if not chunk:
                break
            self.buf += chunk.decode()
        if text in self.buf:
            end = self.buf.find("\n", self.buf.index(text)) + 1 or len(self.buf)
        else:
            end = len(self.buf)
        out, self.buf = self.buf[:end], self.buf[end:]
        return out

    def pending(self, wait):
        """Anything more printed within wait seconds."""
        ready, _, _ = select.select([self.fd], [], [], wait)
        return os.read(self.fd, 65536).decode() if ready else ""


def stop(proc):
    proc.terminate()
    try:
        proc.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate(timeout=5)


class WrapperTest(unittest.TestCase):
    def setUp(self):
        if shutil.which("curl") is None:
            self.skipTest("curl is not installed")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.server = Path(self.tmp.name) / "server.py"
        self.server.write_text(FAKE_SERVER)
        self.server.chmod(0o700)
        self.port = free_port()

    def start(self, password=PASSWORD, stdin=subprocess.DEVNULL, extra_env=None, pw_kind="random", mode="full", why=""):
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "OPENCODE_PASSWORD": password,
            "BWRAP_NET_PUBLISH_ADDR": "127.9.9.1",
        }
        env.update(extra_env or {})
        proc = subprocess.Popen(
            [
                "bash",
                "-c",
                wrapper_source(),
                "bwopencode2-serve",
                str(self.server),
                str(self.port),
                "127.0.0.1",
                "testhost.example.org",
                "testhost-oc",
                pw_kind,
                mode,
                why,
            ],
            env=env,
            stdin=stdin,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(stop, proc)
        self.reader = Reader(proc)
        return proc

    def test_block_has_ssh_command_links_and_password(self):
        self.start()
        out = self.reader.until("Password (new for this session)")
        port = self.port
        self.assertIn(f"ssh -L {port}:127.9.9.1:{port} testhost.example.org", out)
        self.assertIn("ssh testhost-oc", out)
        self.assertIn(f"http://127.0.0.1:{port}/auth/connect/code1", out)
        self.assertIn(f"google-chrome --app=http://127.0.0.1:{port}/auth/connect/code1", out)
        self.assertIn(f"http://127.9.9.1:{port}/auth/connect/code1", out)
        self.assertIn("Press Enter here for a new one", out)
        self.assertIn(f"Password (new for this session): {PASSWORD}", out)

    def test_fixed_password_is_not_printed(self):
        self.start(pw_kind="fixed")
        out = self.reader.until("BWOPENCODE2_SERVE_PASSWORD")
        self.assertIn("/auth/connect/code1", out)
        self.assertNotIn(PASSWORD, out)

    def test_quote_and_backslash_in_the_password_reach_the_server(self):
        # The fake server accepts only the exact password, so a code means curl
        # received it unchanged through its config file.
        self.start(password='pa"ss\\word-123')
        out = self.reader.until("Password (new for this session)")
        self.assertIn("/auth/connect/code1", out)

    def test_failed_pairing_points_at_the_password(self):
        self.start(extra_env={"FAKE_PAIR": "fail"})
        out = self.reader.until("Password (new for this session)")
        self.assertIn("could not get a pairing link", out)
        self.assertIn(f"http://127.0.0.1:{self.port}/\n", out)
        self.assertNotIn("/auth/connect/", out)
        self.assertNotIn("Press Enter", out)

    def test_local_mode_is_only_a_link_and_the_password(self):
        # --serve-open with no browser to start: the link for this machine, why,
        # and the password for the page's "Use password"; none of the ssh block.
        self.start(mode="local", why="no web browser found")
        out = self.reader.until("If the link fails")
        port = self.port
        self.assertIn("could not open a browser (no web browser found).", out)
        self.assertIn(f"Open this on this machine:  http://127.9.9.1:{port}/auth/connect/code1", out)
        self.assertIn("press Enter for a new link", out)
        self.assertIn(f'If the link fails, click "Use password": {PASSWORD}', out)
        for text in ("ssh", "google-chrome", "127.0.0.1", "On this host"):
            self.assertNotIn(text, out)

    def test_local_mode_with_a_fixed_password_does_not_print_it(self):
        self.start(mode="local", why="no desktop", pw_kind="fixed")
        out = self.reader.until("BWOPENCODE2_SERVE_PASSWORD")
        self.assertIn("/auth/connect/code1", out)
        self.assertNotIn(PASSWORD, out)

    def test_local_mode_without_a_link_points_at_the_page_and_password(self):
        self.start(mode="local", why="no desktop", extra_env={"FAKE_PAIR": "fail"})
        out = self.reader.until("If the link fails")
        self.assertIn(f'click "Use password":  http://127.9.9.1:{self.port}/', out)
        self.assertNotIn("/auth/connect/", out)
        self.assertNotIn("press Enter", out)

    def test_quiet_mode_prints_nothing_until_enter_asks_for_a_link(self):
        # The host helper reports whether the browser opened; the wrapper stays silent.
        master, slave = pty.openpty()
        try:
            self.start(stdin=slave, mode="quiet")
            os.close(slave)
            self.assertEqual(self.reader.pending(3), "")
            os.write(master, b"\n")
            out = self.reader.until("If the link fails")
            self.assertIn(f"Open this on this machine:  http://127.9.9.1:{self.port}/auth/connect/code1", out)
            self.assertNotIn("could not open a browser", out)
            self.assertNotIn("ssh", out)
        finally:
            os.close(master)

    def test_enter_prints_a_new_link(self):
        master, slave = pty.openpty()
        try:
            self.start(stdin=slave)
            os.close(slave)
            first = self.reader.until("Password (new for this session)")
            self.assertIn("/auth/connect/code1", first)
            os.write(master, b"\n")
            second = self.reader.until("Password (new for this session)")
            self.assertIn("/auth/connect/code2", second)
            self.assertNotIn("/auth/connect/code1", second)
        finally:
            os.close(master)

    def test_end_of_input_does_not_spin(self):
        # A closed terminal makes read fail at once; the wrapper must keep
        # waiting for the server and not loop printing links.
        master, slave = pty.openpty()
        proc = self.start(stdin=slave)
        os.close(slave)
        out = self.reader.until("Password (new for this session)")
        self.assertIn("/auth/connect/code1", out)
        os.close(master)
        time.sleep(2)
        self.assertIsNone(proc.poll())
        self.assertEqual(self.reader.pending(0.5), "", "the wrapper printed more after end of input")


class OpenHelperTest(unittest.TestCase):
    """serve_open_run, the host-side helper of --serve-open."""

    def setUp(self):
        if shutil.which("curl") is None:
            self.skipTest("curl is not installed")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        tmp = Path(self.tmp.name)
        server = tmp / "server.py"
        server.write_text(FAKE_SERVER)
        self.port = free_port()
        self.argv_log = tmp / "browser-argv"
        self.browser = tmp / "browser"
        self.browser.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$@\" > {self.argv_log}\n")
        self.browser.chmod(0o700)
        self.server_env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "OPENCODE_PASSWORD": PASSWORD,
        }
        self.server = server

    def start_server(self, **extra):
        proc = subprocess.Popen(
            ["python3", str(self.server), "serve", "--port", str(self.port)],
            env={**self.server_env, **extra},
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.addCleanup(lambda: (proc.kill(), proc.wait()))
        return proc

    def run_helper(self, app, pid_expr='"$$"', timeout=30, browser=None, random=1):
        script = f"""
set -euo pipefail
source "{WRAPPER}"
SERVE_ADDR=127.0.0.1
SERVE_PORT={self.port}
SERVE_PASSWORD='{PASSWORD}'
SERVE_PASSWORD_RANDOM={random}
SERVE_OPEN_WAIT_SECONDS=1
SERVE_OPEN_BIN="{browser or self.browser}"
SERVE_OPEN_APP={app}
serve_open_run {pid_expr} "$(bwrap_proc_start_time "$$")"
"""
        # The stub browser is started in the background and detached; give it a moment.
        result = subprocess.run(
            ["bash", "-c", script],
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.tmp.name},
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        for _ in range(30):
            if self.argv_log.exists() and self.argv_log.read_text().endswith("\n"):
                break
            time.sleep(0.1)
        return result

    def test_chromium_family_gets_an_app_window_with_a_signed_in_link(self):
        self.start_server()
        result = self.run_helper(app=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.argv_log.read_text().split("\n")[:-1],
            [f"--app=http://127.0.0.1:{self.port}/auth/connect/code1"],
        )
        self.assertIn(f"OpenCode web UI on 127.0.0.1:{self.port}, opened in browser.", result.stderr)
        self.assertEqual(result.stderr.strip().count("\n"), 0, "one line when the browser opened")
        self.assertNotIn(PASSWORD, result.stderr)

    def test_other_browsers_get_the_plain_link(self):
        self.start_server()
        result = self.run_helper(app=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.argv_log.read_text().split("\n")[:-1],
            [f"http://127.0.0.1:{self.port}/auth/connect/code1"],
        )

    def test_no_link_opens_the_login_page(self):
        self.start_server(FAKE_PAIR="fail")
        result = self.run_helper(app=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.argv_log.read_text().split("\n")[:-1],
            [f"--app=http://127.0.0.1:{self.port}/"],
        )
        self.assertIn("opened in browser.", result.stderr)
        self.assertIn(f'The server gave no sign-in link: click "Use password": {PASSWORD}', result.stderr)

    def _failing_browser(self, status):
        stub = Path(self.tmp.name) / f"failing-browser-{status}"
        stub.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$@\" >> {self.argv_log}.tries\nexit {status}\n")
        stub.chmod(0o700)
        return stub

    def test_a_browser_that_fails_gives_a_fresh_link_and_the_password(self):
        # The failed attempt used code1 (the browser may have fetched it), so the
        # link to open by hand must be a new one.
        self.start_server()
        result = self.run_helper(app=1, browser=self._failing_browser(3))
        self.assertEqual(result.returncode, 0, result.stderr)
        err = result.stderr
        self.assertIn("could not open a browser (failing-browser-3 exited with status 3).", err)
        self.assertIn(f"Open this on this machine:  http://127.0.0.1:{self.port}/auth/connect/code2", err)
        self.assertIn("press Enter for a new link", err)
        self.assertIn(f'If the link fails, click "Use password": {PASSWORD}', err)
        self.assertNotIn("opened in", err)
        tries = Path(f"{self.argv_log}.tries").read_text()
        self.assertIn("/auth/connect/code1", tries)

    def test_a_fixed_password_is_not_printed_in_the_fallback(self):
        self.start_server()
        result = self.run_helper(app=1, browser=self._failing_browser(1), random=0)
        self.assertIn("could not open a browser", result.stderr)
        self.assertIn("BWOPENCODE2_SERVE_PASSWORD", result.stderr)
        self.assertNotIn(PASSWORD, result.stderr)

    def test_a_browser_that_exits_cleanly_counts_as_opened(self):
        # Chrome hands the link to a window that is already open and exits 0.
        self.start_server()
        result = self.run_helper(app=1, browser=self._failing_browser(0))
        self.assertIn("opened in failing-browser-0.", result.stderr)
        self.assertNotIn("could not open", result.stderr)

    def test_a_browser_still_running_after_the_wait_counts_as_opened(self):
        self.start_server()
        slow = Path(self.tmp.name) / "slow-opened-browser"
        slow.write_text("#!/bin/sh\nsleep 6\n")
        slow.chmod(0o700)
        started = time.monotonic()
        result = self.run_helper(app=1, browser=slow)
        self.assertLess(time.monotonic() - started, 5, "the helper must not wait for the browser to end")
        self.assertIn("opened in slow-opened-browser.", result.stderr)

    def test_launcher_gone_opens_nothing(self):
        # A pid that cannot be the launcher: the helper must stop without waiting for the server.
        started = time.monotonic()
        result = self.run_helper(app=1, pid_expr="999999")
        self.assertLess(time.monotonic() - started, 10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.argv_log.exists())

    def test_start_runs_the_helper_in_the_background(self):
        # serve_open_start returns at once (the launcher then execs the sandbox);
        # the helper opens the browser later, while the launcher's pid is alive.
        # The shell ends in exec, as the launcher does: the pid must stay the same.
        self.start_server()
        script = f"""
set -euo pipefail
source "{WRAPPER}"
SERVE_ADDR=127.0.0.1
SERVE_PORT={self.port}
SERVE_PASSWORD='{PASSWORD}'
SERVE_OPEN=1
SERVE_OPEN_BIN="{self.browser}"
SERVE_OPEN_APP=1
DRY_RUN=0
started=$SECONDS
serve_open_start
((SECONDS - started < 2)) || {{ echo "serve_open_start blocked" >&2; exit 1; }}
exec sleep 4
"""
        result = subprocess.run(
            ["bash", "-c", script],
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.tmp.name},
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.argv_log.read_text().split("\n")[:-1],
            [f"--app=http://127.0.0.1:{self.port}/auth/connect/code1"],
        )

    def test_the_browser_does_not_inherit_the_launchers_descriptors(self):
        # The launcher holds the database session lock on a descriptor; a browser
        # that kept it would hold the lock for as long as its window lives and
        # refuse the next launch.  The stub keeps running while the lock is tried.
        self.start_server()
        lock = Path(self.tmp.name) / "session.lock"
        fds = Path(self.tmp.name) / "browser-fds"
        slow = Path(self.tmp.name) / "slow-browser"
        slow.write_text(f"#!/bin/sh\nls /proc/$$/fd > {fds}\nsleep 8\n")
        slow.chmod(0o700)
        script = f"""
set -euo pipefail
source "{WRAPPER}"
SERVE_ADDR=127.0.0.1
SERVE_PORT={self.port}
SERVE_PASSWORD='{PASSWORD}'
SERVE_OPEN=1
SERVE_OPEN_BIN="{slow}"
SERVE_OPEN_APP=1
DRY_RUN=0
exec 200>> "{lock}"
flock -n 200
serve_open_start
exec sleep 3
"""
        subprocess.run(
            ["bash", "-c", script],
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.tmp.name},
            check=True,
            timeout=30,
        )
        for _ in range(60):
            if fds.exists() and fds.read_text().endswith("\n"):
                break
            time.sleep(0.1)
        self.assertNotIn("200", fds.read_text().split())
        # The launcher (the sleep that holds the lock, like the sandbox) has ended and
        # the browser still runs: the lock must be free.
        free = subprocess.run(["flock", "-n", str(lock), "true"])
        self.assertEqual(free.returncode, 0, "the browser still holds the launcher's lock")

    def test_dry_run_starts_nothing(self):
        self.start_server()
        script = f"""
set -euo pipefail
source "{WRAPPER}"
SERVE_ADDR=127.0.0.1
SERVE_PORT={self.port}
SERVE_PASSWORD='{PASSWORD}'
SERVE_OPEN=1
SERVE_OPEN_BIN="{self.browser}"
DRY_RUN=1
serve_open_start
sleep 3
"""
        result = subprocess.run(
            ["bash", "-c", script],
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.tmp.name},
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.argv_log.exists())

    def test_the_password_is_not_in_the_browser_arguments(self):
        self.start_server()
        self.run_helper(app=1)
        self.assertNotIn(PASSWORD, self.argv_log.read_text())
        # The pairing code is the only secret the link holds.
        self.assertIsNotNone(re.search(r"/auth/connect/code\d+\n$", self.argv_log.read_text()))


class StartMessageTest(unittest.TestCase):
    """serve_print_info: what the launcher prints before the sandbox starts."""

    def message(self, serve_open, dry_run=0):
        script = f"""
set -euo pipefail
source "{WRAPPER}"
SERVE_ADDR=127.52.255.1
SERVE_PORT=24700
NET_SHARE=1
SERVE_OPEN={serve_open}
SERVE_OPEN_BIN=/usr/bin/google-chrome
SERVE_OPEN_APP=1
DRY_RUN={dry_run}
serve_print_info
"""
        result = subprocess.run(
            ["bash", "-c", script],
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": "/nonexistent"},
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stderr

    def test_serve_open_prints_one_line(self):
        lines = [x for x in self.message(1).split("\n") if x]
        self.assertEqual(lines, ["bwopencode2: starting the sandboxed OpenCode 2 web UI on 127.52.255.1:24700"])

    def test_serve_keeps_its_text(self):
        out = self.message(0)
        self.assertIn("starting the sandboxed OpenCode 2 web UI on 127.52.255.1:24700 (this host only)", out)
        self.assertIn(
            "The ssh command, a one-time sign-in link and the password are printed once the server is up.", out
        )
        self.assertNotIn("--serve-open", out)

    def test_serve_open_dry_run_names_the_browser_it_would_start(self):
        out = self.message(1, dry_run=1)
        self.assertIn("/usr/bin/google-chrome --app=http://127.52.255.1:24700/auth/connect/CODE will be started", out)


if __name__ == "__main__":
    unittest.main()
