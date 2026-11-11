#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""xenstored-socket -> /dev/xen/xenbus relay, for a driver domain.

xen-vhost-frontend's xenstore client (mathieupoirier/xen-sys, crate xen-store)
only connects to xenstored's Unix socket, which exists only where xenstored
runs (here Dom0). A driver domain reaches xenstore through the kernel's
/dev/xen/xenbus, which speaks the same wire protocol. This serves the socket
path in DomD and gives each client its own xenbus file (own watches and
transactions).

Every client costs one xenbus fd and two threads for as long as it is connected,
and both are released when it goes away. (The first version never closed the
xenbus fd: after 1,024 clients, a few minutes of `xl` and `xenstore-ls` calls on
the Pi 5 bench, accept() failed with EMFILE and the relay died, leaving its
socket file behind. ZRE#63.)

XS_RELAY_SOCK and XS_RELAY_XENBUS override the two paths, for the test."""
import os, select, socket, sys, threading, time

PATH = os.environ.get("XS_RELAY_SOCK", "/var/run/xenstored/socket")
XENBUS = os.environ.get("XS_RELAY_XENBUS", "/dev/xen/xenbus")


def pump_in(c, fd, done):
    try:
        while True:
            b = c.recv(65536)
            if not b:
                break
            os.write(fd, b)
    except OSError:
        pass
    done.set()


def pump_out(c, fd, done):
    # A blocking read on xenbus cannot be interrupted by a close, so poll with a
    # timeout and leave as soon as the other direction has finished.
    try:
        while not done.is_set():
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                b = os.read(fd, 65536)
                if not b:
                    break
                c.sendall(b)
    except OSError:
        pass
    done.set()


def serve(c):
    try:
        fd = os.open(XENBUS, os.O_RDWR)
    except OSError as e:
        print("xs-sock-relay: open %s: %s" % (XENBUS, e), flush=True)
        c.close()
        return
    done = threading.Event()
    t = threading.Thread(target=pump_in, args=(c, fd, done), daemon=True)
    t.start()
    pump_out(c, fd, done)
    try:
        c.shutdown(socket.SHUT_RDWR)  # wakes pump_in's recv
    except OSError:
        pass
    t.join()
    c.close()
    os.close(fd)


def main():
    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    try:
        os.unlink(PATH)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(PATH)
    srv.listen(16)
    print("xs-sock-relay: %s -> %s" % (PATH, XENBUS), flush=True)
    n = 0
    while True:
        try:
            c, _ = srv.accept()
        except OSError as e:
            print("xs-sock-relay: accept: %s" % e, flush=True)
            time.sleep(0.1)
            continue
        n += 1
        print("xs-sock-relay: client %d" % n, flush=True)
        try:
            threading.Thread(target=serve, args=(c,), daemon=True).start()
        except OSError as e:
            print("xs-sock-relay: client %d dropped: %s" % (n, e), flush=True)
            c.close()


main()
