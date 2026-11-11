#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""Regression test for xs-sock-relay.py (ZRE#63): the relay must not leak a
xenbus fd per client. A FIFO stands in for /dev/xen/xenbus (whatever a client
sends comes back), the relay runs with a 64-fd limit, and 400 clients connect,
exchange one message and leave. The first version died at the 64th."""
import os, resource, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
CLIENTS = 400


def main():
    d = tempfile.mkdtemp()
    sock, fifo = os.path.join(d, "xs.sock"), os.path.join(d, "xenbus")
    os.mkfifo(fifo)
    env = dict(os.environ, XS_RELAY_SOCK=sock, XS_RELAY_XENBUS=fifo)

    def limit():
        resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))

    p = subprocess.Popen([sys.executable, os.path.join(HERE, "xs-sock-relay.py")],
                         env=env, preexec_fn=limit, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        for _ in range(100):
            if os.path.exists(sock):
                break
            time.sleep(0.05)
        for i in range(CLIENTS):
            c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            c.settimeout(5)
            msg = b"hello %d" % i
            got = b""
            try:
                c.connect(sock)
                c.sendall(msg)
                while len(got) < len(msg):
                    b = c.recv(64)
                    if not b:
                        break
                    got += b
            except OSError as e:
                print("FAIL: client %d: %s (relay %s)" % (i, e, "died" if p.poll() is not None else "alive")); return 1
            c.close()
            time.sleep(0.12)  # the FIFO is shared: let the last handler leave before the next client
            if got != msg:
                print("FAIL: client %d got %r, wanted %r" % (i, got, msg)); return 1
            if p.poll() is not None:
                print("FAIL: relay exited after %d clients (rc=%s)" % (i, p.returncode)); return 1
        time.sleep(1.5)  # let the last handlers finish
        n = len(os.listdir("/proc/%d/fd" % p.pid))
        if n > 12:
            print("FAIL: %d fds open after %d clients left" % (n, CLIENTS)); return 1
        print("PASS: %d clients through a 64-fd limit, %d fds open afterwards" % (CLIENTS, n))
        return 0
    finally:
        p.kill(); p.wait()


sys.exit(main())
