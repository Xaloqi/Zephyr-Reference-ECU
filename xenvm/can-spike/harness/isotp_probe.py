#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""UDS over ISO-TP with the kernel's CAN_ISOTP socket, Python stdlib only.
   isotp_probe.py IFACE [TX_ID RX_ID]   (default 7E0 7E8, physical addressing)
Prints 'UDS <req> -> <resp>' or 'UDS <req> -> TIMEOUT'."""
import socket, struct, sys

SOL_CAN_ISOTP = 106          # SOL_CAN_BASE + CAN_ISOTP
CAN_ISOTP_OPTS = 1
CAN_ISOTP_TX_PADDING = 0x004

iface = sys.argv[1]
tx_id = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0x7E0
rx_id = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0x7E8

s = socket.socket(socket.AF_CAN, socket.SOCK_DGRAM, socket.CAN_ISOTP)
# struct can_isotp_options: flags, frame_txtime, ext_address, txpad, rxpad, rx_ext_address
s.setsockopt(SOL_CAN_ISOTP, CAN_ISOTP_OPTS, struct.pack("=IIBBBB", CAN_ISOTP_TX_PADDING, 0, 0, 0xAA, 0, 0))
s.bind((iface, rx_id, tx_id))
s.settimeout(2.0)
hx = lambda b: " ".join("%02x" % x for x in b)
print("ISOTP %s tx 0x%03X rx 0x%03X" % (iface, tx_id, rx_id), flush=True)
for req in ("3e 00", "10 03", "22 f1 90", "27 01", "27 01"):
    r = bytes.fromhex(req)
    s.send(r)
    try:
        resp = s.recv(4096)
        print("UDS %s -> %s" % (hx(r), hx(resp)), flush=True)
    except socket.timeout:
        print("UDS %s -> TIMEOUT" % hx(r), flush=True)
