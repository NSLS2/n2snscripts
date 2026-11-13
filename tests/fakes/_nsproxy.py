"""Shared helpers for the fake network backends (pasta, slirp4netns).

The fakes stand in for the real backends where /dev/net/tun is missing (for
example inside a development sandbox).  They really create or join the
namespaces and really forward TCP, so the launchers can be tested end to end:

- NsProxy forks a process that joins the user and network namespace of a
  target pid and creates sockets there on request (connect, listen), passing
  them back with SCM_RIGHTS.  The caller stays in the host namespace.
- forward() accepts on a listening socket and splices each connection to a
  socket returned by a callback.
"""

import ctypes
import json
import os
import socket
import struct
import subprocess
import threading

PR_SET_PDEATHSIG = 1


def _die_with_parent():
    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl(PR_SET_PDEATHSIG, 9, 0, 0, 0)


def _keep_caps_across_exec():
    """Make the capabilities this process holds survive execve.

    After joining a user namespace we own, this process has every capability
    in it.  The real slirp4netns configures the interface right there, with
    ioctls in the same process.  The fake execs `ip` instead, and execve
    clears the capability sets unless the process is uid 0 in the namespace:
    true when the launcher mapped the caller to root, false with the identity
    map the slirp4netns launch uses (_NET_NS_IDENTITY).  Raising each
    permitted capability into the ambient set keeps them across the exec, so
    the fake can do what the real program does.
    """
    libc = ctypes.CDLL(None, use_errno=True)
    header = ctypes.create_string_buffer(struct.pack("II", 0x20080522, 0))  # v3, this thread
    data = ctypes.create_string_buffer(24)  # 2 x {effective, permitted, inheritable}
    if libc.capget(header, data) != 0:
        return
    e0, p0, i0, e1, p1, i1 = struct.unpack("6I", data.raw)
    data = ctypes.create_string_buffer(struct.pack("6I", e0, p0, p0, e1, p1, p1))
    if libc.capset(header, data) != 0:
        return
    for cap in range(64):
        if (p0 | (p1 << 32)) >> cap & 1:
            libc.prctl(47, 2, cap, 0, 0)  # PR_CAP_AMBIENT, PR_CAP_AMBIENT_RAISE


class NsProxy:
    def __init__(self, pid):
        a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        self.pid = os.fork()
        if self.pid == 0:
            a.close()
            _die_with_parent()
            for ns, flag in (("user", os.CLONE_NEWUSER), ("net", os.CLONE_NEWNET)):
                fd = os.open("/proc/%d/ns/%s" % (pid, ns), os.O_RDONLY)
                os.setns(fd, flag)
                os.close(fd)
            _keep_caps_across_exec()
            self._serve(b)
            os._exit(0)
        b.close()
        self.sock = a
        self.lock = threading.Lock()

    @staticmethod
    def _serve(chan):
        while True:
            msg = chan.recv(65536)
            if not msg:
                return
            req = json.loads(msg)
            try:
                if req["op"] == "connect":
                    s = socket.create_connection((req["host"], req["port"]), timeout=5)
                    s.settimeout(None)
                elif req["op"] == "listen":
                    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    s.bind((req["host"], req["port"]))
                    s.listen(16)
                elif req["op"] == "udp":
                    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    s.bind((req["host"], req["port"]))
                elif req["op"] == "run":
                    r = subprocess.run(req["cmd"], capture_output=True, text=True)
                    chan.send(json.dumps({"rc": r.returncode, "err": r.stderr}).encode())
                    continue
                else:
                    raise OSError("unknown op")
                socket.send_fds(chan, [b"ok"], [s.fileno()])
                s.close()
            except OSError as e:
                chan.send(json.dumps({"error": str(e)}).encode())

    def _request(self, **req):
        with self.lock:
            self.sock.send(json.dumps(req).encode())
            msg, fds, _, _ = socket.recv_fds(self.sock, 65536, 1)
        if not fds:
            reply = json.loads(msg)
            if "rc" in reply:
                return reply
            raise OSError(reply.get("error", "proxy error"))
        return socket.socket(fileno=fds[0])

    def connect(self, host, port):
        return self._request(op="connect", host=host, port=port)

    def listen(self, host, port):
        return self._request(op="listen", host=host, port=port)

    def udp(self, host, port):
        return self._request(op="udp", host=host, port=port)

    def run(self, cmd):
        return self._request(op="run", cmd=cmd)


def _pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    try:
        dst.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def forward(listener, connect, on_open=None, on_close=None):
    """Splice each connection accepted on LISTENER to connect().  on_open(peer)
    returns a token given to on_close(token) once both directions are done."""

    def conn(c, t, token):
        threads = [threading.Thread(target=_pipe, args=(a, b), daemon=True) for a, b in ((c, t), (t, c))]
        for th in threads:
            th.start()
        for th in threads:
            th.join()
        c.close()
        t.close()
        if on_close:
            on_close(token)

    def loop():
        while True:
            try:
                c, peer = listener.accept()
            except OSError:
                return
            try:
                t = connect()
            except OSError:
                c.close()
                continue
            token = on_open(peer) if on_open else None
            threading.Thread(target=conn, args=(c, t, token), daemon=True).start()

    threading.Thread(target=loop, daemon=True).start()


def port_range(spec):
    """Ports of a pasta port list: N, LO-HI, comma-separated."""
    ports = []
    for part in spec.split(","):
        lo, _, hi = part.partition("-")
        ports.extend(range(int(lo), int(hi or lo) + 1))
    return ports
