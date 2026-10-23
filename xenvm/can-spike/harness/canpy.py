#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""Minimal SocketCAN tool, Python stdlib only.
  canpy.py send IFACE ID#HEX [ID#HEX ...]   (ID > 0x7FF or 8 hex digits = extended)
  canpy.py dump IFACE SECONDS [MAXFRAMES] TAG
"""
import socket, struct, sys, time

FMT = "=IB3x8s"
EFF = socket.CAN_EFF_FLAG


def parse(spec):
    i, d = spec.split("#")
    cid = int(i, 16)
    if len(i) == 8 or cid > 0x7FF:
        cid |= EFF
    data = bytes.fromhex(d)
    return cid, data


def fmt(cid, data):
    if cid & EFF:
        s = "%08X" % (cid & socket.CAN_EFF_MASK)
    else:
        s = "%03X" % (cid & socket.CAN_SFF_MASK)
    return "%s [%d] %s" % (s, len(data), " ".join("%02X" % b for b in data))


def open_sock(iface):
    s = socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
    s.bind((iface,))
    return s


def main():
    cmd, iface = sys.argv[1], sys.argv[2]
    s = open_sock(iface)
    if cmd == "send":
        tag = "TX"
        for spec in sys.argv[3:]:
            cid, data = parse(spec)
            s.send(struct.pack(FMT, cid, len(data), data.ljust(8, b"\0")))
            print("%s %s %s" % (tag, iface, fmt(cid, data)), flush=True)
            time.sleep(0.05)
    elif cmd == "dump":
        secs = float(sys.argv[3])
        maxn = int(sys.argv[4]) if len(sys.argv) > 4 else 1 << 30
        tag = sys.argv[5] if len(sys.argv) > 5 else "RX"
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
