"""Exercise bwopencode2 --serve's local pairing request without a real server."""

import os
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


class ServeTimeoutTest(unittest.TestCase):
    def test_stalled_pairing_request_returns_to_server_wait(self):
        if shutil.which("curl") is None:
            self.skipTest("curl is not installed")

        source = WRAPPER.read_text()
        match = re.search(
            r"read -r -d '' SERVE_WRAPPER << 'SERVE_WRAPPER_EOF' \|\| true\n(.*?)\nSERVE_WRAPPER_EOF", source, re.S
        )
        self.assertIsNotNone(match)
        with tempfile.TemporaryDirectory() as tmp:
            server = Path(tmp) / "server.py"
            server.write_text(
                """#!/usr/bin/env python3
import http.server
import sys
import threading
import time

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(401)
        self.end_headers()

    def do_POST(self):
        time.sleep(30)  # curl, not the server, must end this request

    def log_message(self, *args):
        pass

httpd = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[-1])), Handler)
httpd.daemon_threads = True
threading.Timer(30, httpd.shutdown).start()
httpd.serve_forever()
"""
            )
            server.chmod(0o700)
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            proc = subprocess.Popen(
                ["bash", "-c", match.group(1), "bwopencode2-serve", str(server), str(port), "127.0.0.1"],
                env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "OPENCODE_PASSWORD": "test-only-password"},
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                deadline = time.monotonic() + 9
                data = ""
                fd = proc.stderr.fileno()
                # os.read, not readline: select cannot see lines a buffered reader already holds.
                while time.monotonic() < deadline and "could not get a pairing link" not in data:
                    ready, _, _ = select.select([fd], [], [], max(0, deadline - time.monotonic()))
                    if not ready:
                        break
                    chunk = os.read(fd, 65536)
                    if not chunk:
                        break
                    data += chunk.decode()
                self.assertIn("could not get a pairing link", data)
            finally:
                proc.terminate()
                try:
                    proc.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.communicate(timeout=3)


if __name__ == "__main__":
    unittest.main()
