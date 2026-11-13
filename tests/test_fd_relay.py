"""Tests for the descriptor relay in lib/bwrap_sandbox_lib.sh.

    python3 -m unittest discover -s tests -p 'test_*.py'

The relay list (_BWRAP_FD_RELAY) is read by two parties that must agree on
how many words each entry takes: the shim (_BWRAP_FD_RELAY_SHIM), which
shifts past each entry as it runs, and _bwrap_fd_data_numbers, which finds
the `data` entries so the launcher can export their text.  If the walker
steps differently from the shim it loses its place, skips data entries, and
their files (resolv.conf, hosts) reach the sandbox empty, with no error.
These tests give one list to both and check every data descriptor arrives.
"""

import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "lib", "bwrap_sandbox_lib.sh")
HELPER = os.path.join(HERE, "..", "lib", "bwrap_netlog.py")

# Run the launcher's own code: build the list, walk it, export the data the
# way launch_sandbox does, then exec the shim and read each data descriptor
# through the descriptor itself (as bwrap does), not by reopening it.
DRIVER = r"""
source "$1" 2>/dev/null
shift
_BWRAP_FD_RELAY=("$@")
declare -A _BWRAP_FD_DATA=([10]=RESOLV [11]=HOSTS [12]=CONTEXT)
_bwrap_fd_data_numbers
echo "walker: ${_BWRAP_FD_DATA_NUMS[*]}"
env=()
for n in "${_BWRAP_FD_DATA_NUMS[@]}"; do env+=("_BWRAP_FD_DATA_${n}=${_BWRAP_FD_DATA[${n}]}"); done
exec env "${env[@]}" bash -c "${_BWRAP_FD_RELAY_SHIM}" bwrap-fd-relay "${_BWRAP_FD_RELAY[@]}" -- \
    sh -c 'for n in 10 11 12; do printf "%s=%s\n" "$n" "$(eval "cat <&$n")"; done' 2>/dev/null
"""

DATA = ["10", "data", "11", "data", "12", "data"]


def relay(*entries):
    got = subprocess.run(
        ["bash", "-c", DRIVER, "_", LIB, *entries],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    out = got.stdout.decode()
    fields = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    walker = next((ln for ln in out.splitlines() if ln.startswith("walker:")), "")
    return walker, fields, got


class FdRelayTest(unittest.TestCase):
    def assert_all_data_arrive(self, *entries):
        walker, fields, got = relay(*entries)
        self.assertEqual(walker, "walker: 10 11 12", got.stderr.decode())
        self.assertEqual(fields, {"10": "RESOLV", "11": "HOSTS", "12": "CONTEXT"})

    def test_data_alone(self):
        self.assert_all_data_arrive(*DATA)

    def test_after_the_network_log_entries_pasta(self):
        """note, spawn (relay binds for itself: "- -") and append first."""
        self.assert_all_data_arrive(
            "2",
            "note",
            "MARK",
            "2",
            "spawn",
            sys.executable,
            HELPER,
            "127.0.0.1:5399",
            "127.0.0.1:9",
            "-",
            "-",
            "2",
            "append",
            os.devnull,
            *DATA,
        )

    def test_after_the_network_log_entries_slirp4netns(self):
        """spawn with pre-bound descriptors, as under slirp4netns."""
        r, w = os.pipe()  # two real descriptors to stand in for the sockets
        try:
            os.dup2(r, 88)
            os.dup2(w, 89)
            self.assert_all_data_arrive(
                "2",
                "note",
                "MARK",
                "2",
                "spawn",
                sys.executable,
                HELPER,
                "127.0.0.1:5398",
                "127.0.0.1:9",
                "88",
                "89",
                "2",
                "append",
                os.devnull,
                *DATA,
            )
        finally:
            for fd in (r, w, 88, 89):
                try:
                    os.close(fd)
                except OSError:
                    pass


if __name__ == "__main__":
    unittest.main()
