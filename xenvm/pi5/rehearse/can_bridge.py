#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""Join two SocketCAN interfaces into one bus, Python stdlib only.
   can_bridge.py IFACE_A IFACE_B
Every frame seen on one is sent on the other. The rehearsal uses it to make vcan
can0 and can1 behave like the Pi 5 HAT's two channels on one wire. A raw socket
does not receive its own frames (CAN_RAW_RECV_OWN_MSGS defaults to 0), so a
forwarded frame is not forwarded back."""
import socket, sys, threading


def pump(src, dst):
    while True:
        dst.send(src.recv(16))


a, b = (socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW) for _ in range(2))
a.bind((sys.argv[1],))
b.bind((sys.argv[2],))
threading.Thread(target=pump, args=(b, a), daemon=True).start()
print("bridge %s <-> %s" % (sys.argv[1], sys.argv[2]), flush=True)
pump(a, b)
