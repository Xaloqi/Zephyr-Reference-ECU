#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""Print every CAN frame on a SocketCAN interface, Python stdlib only.
   can_dump.py IFACE SECONDS [MAXFRAMES] [TAG]
Prints '<TAG> <IFACE> <ID> [<len>] <data>' per classic frame, then a frame count.
CAN FD frames (on an interface with MTU 72) print as '<ID> [<len>] FD|FDBRS <data>'."""
import socket, struct, sys, time

FMT = "=IB3x8s"
FDFMT = "=IBB2x64s"
SOL_CAN_RAW, CAN_RAW_FD_FRAMES = 101, 5
CANFD_BRS = 0x01


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
    s.setsockopt(SOL_CAN_RAW, CAN_RAW_FD_FRAMES, 1)
    s.bind((iface,))
    end = time.time() + secs
    n = 0
    while n < maxn and time.time() < end:
        s.settimeout(max(0.01, end - time.time()))
        try:
            fr = s.recv(72)
        except socket.timeout:
            break
        if len(fr) == 72:
            cid, dlc, flags, data = struct.unpack(FDFMT, fr)
            f = "FDBRS" if flags & CANFD_BRS else "FD"
            idl, rest = fmt(cid, data[:dlc]).split(" ", 1)
            ln, d = rest.split("]", 1)
            print("%s %s %s %s] %s%s" % (tag, iface, idl, ln, f, d), flush=True)
        else:
            cid, dlc, data = struct.unpack(FMT, fr)
            print("%s %s %s" % (tag, iface, fmt(cid, data[:dlc])), flush=True)
        n += 1
    print("%s %s: %d frame(s)" % (tag, iface, n), flush=True)


main()
