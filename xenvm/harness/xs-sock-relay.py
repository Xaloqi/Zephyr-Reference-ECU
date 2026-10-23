#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""xenstored-socket -> /dev/xen/xenbus relay, for a driver domain.

xen-vhost-frontend's xenstore client (mathieupoirier/xen-sys, crate xen-store)
only connects to xenstored's Unix socket, which exists only where xenstored
runs (here Dom0). A driver domain reaches xenstore through the kernel's
/dev/xen/xenbus, which speaks the same wire protocol. This serves the socket
path in DomD and gives each client its own xenbus file (own watches and
transactions)."""
import os, socket, sys, threading

PATH = "/var/run/xenstored/socket"


def pump_in(c, fd):
    try:
        while True:
            b = c.recv(65536)
            if not b:
                break
            os.write(fd, b)
    except OSError:
        pass
    c.close()


def pump_out(c, fd):
    try:
        while True:
            b = os.read(fd, 65536)
            if not b:
                break
            c.sendall(b)
    except OSError:
        pass


def main():
    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    try:
        os.unlink(PATH)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(PATH)
    srv.listen(16)
    print("xs-sock-relay: %s -> /dev/xen/xenbus" % PATH, flush=True)
    n = 0
    while True:
        c, _ = srv.accept()
        fd = os.open("/dev/xen/xenbus", os.O_RDWR)
        n += 1
        print("xs-sock-relay: client %d" % n, flush=True)
        threading.Thread(target=pump_in, args=(c, fd), daemon=True).start()
        threading.Thread(target=pump_out, args=(c, fd), daemon=True).start()


main()
