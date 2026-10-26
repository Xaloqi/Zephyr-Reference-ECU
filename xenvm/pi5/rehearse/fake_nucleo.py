#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""A stand-in for the NUCLEO in the QEMU rehearsal: UDS over the kernel's
CAN_ISOTP on IFACE, request 0x7E0, response 0x7E8 (ECU 0). It answers only the
five requests the bench sends, with ReferenceBCM's response shapes. It is not
EDS, and it says so in every seed (6 bytes of 'FAKE..' text), so a rehearsal
log can never be mistaken for a NUCLEO run.
   fake_nucleo.py IFACE"""
import socket, struct, sys

SOL_CAN_ISOTP, CAN_ISOTP_OPTS, CAN_ISOTP_TX_PADDING = 106, 1, 0x004
s = socket.socket(socket.AF_CAN, socket.SOCK_DGRAM, socket.CAN_ISOTP)
s.setsockopt(SOL_CAN_ISOTP, CAN_ISOTP_OPTS, struct.pack("=IIBBBB", CAN_ISOTP_TX_PADDING, 0, 0, 0xAA, 0, 0))
s.bind((sys.argv[1], 0x7E0, 0x7E8))
n = 0
print("fake NUCLEO on %s: 0x7E0 -> 0x7E8" % sys.argv[1], flush=True)
while True:
    r = s.recv(4095)
    if r == b"\x3e\x00":
        s.send(b"\x7e\x00")
    elif r == b"\x10\x03":
        s.send(bytes.fromhex("500300 1901f4"))
    elif r == b"\x22\xf1\x90":
        s.send(b"\x62\xf1\x90" + bytes(17))
    elif r == b"\x27\x01":
        n += 1
        s.send(b"\x67\x01" + b"FAKE" + bytes([0x4E, n]) + struct.pack(">H", n))
    else:
        s.send(bytes([0x7F, r[0], 0x11]))
