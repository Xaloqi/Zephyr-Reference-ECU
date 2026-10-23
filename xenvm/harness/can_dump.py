#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""Print every classic CAN frame on a SocketCAN interface, Python stdlib only.
   can_dump.py IFACE SECONDS [MAXFRAMES] [TAG]
Prints '<TAG> <IFACE> <ID> [<len>] <data>' per frame, then a frame count."""
import socket, struct, sys, time

FMT = "=IB3x8s"


def fmt(cid, data):
    if cid & socket.CAN_EFF_FLAG:
        s = "%08X" % (cid & socket.CAN_EFF_MASK)
    else:
        s = "%03X" % (cid & socket.CAN_SFF_MASK)
    return "%s [%d] %s" % (s, len(data), " ".join("%02X" % b for b in data))


def main():
    iface, secs = sys.argv[1], float(sys.argv[2])
    maxn = int(sys.argv[3]) if len(sys.argv) > 3 else 1 << 30
    tag = sys.argv[4] if len(sys.argv) > 4 else "RX"
    s = socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
    s.bind((iface,))
    end = time.time() + secs
    n = 0
    while n < maxn and time.time() < end:
        s.settimeout(max(0.01, end - time.time()))
        try:
            fr = s.recv(16)
        except socket.timeout:
            break
        cid, dlc, data = struct.unpack(FMT, fr)
        print("%s %s %s" % (tag, iface, fmt(cid, data[:dlc])), flush=True)
        n += 1
    print("%s %s: %d frame(s)" % (tag, iface, n), flush=True)


main()
