# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""Minimal DoIP (ISO 13400-2) tester for the xenvm harness.

Routing activation, then TesterPresent, ReadDID F190, extended session and two
SecurityAccess seed requests. Every frame is printed as hex. It uses only the
Python standard library, because the public xaloqi-tester package has no DoIP
transport (DoIP is part of TestLab Pro).
"""
import socket
import struct
import sys

SA, TA = 0x0E00, 0xE400          # tester / ECU logical addresses
REQUESTS = (b"\x3e\x00", b"\x22\xf1\x90", b"\x10\x03", b"\x27\x01", b"\x27\x01")


def frame(ptype, payload):
    return struct.pack(">BBHI", 0x02, 0xFD, ptype, len(payload)) + payload


def recv_exact(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError("connection closed")
        b += c
    return b


def rx(s):
    h = recv_exact(s, 8)
    p = recv_exact(s, struct.unpack(">I", h[4:])[0])
    print("DOIP RX", (h + p).hex(" "), flush=True)
    return struct.unpack(">H", h[2:4])[0], p


def tx(s, b):
    print("DOIP TX", b.hex(" "), flush=True)
    s.sendall(b)


def uds(s, req):
    tx(s, frame(0x8001, struct.pack(">HH", SA, TA) + req))
    while True:
        ptype, p = rx(s)
        if ptype == 0x8001:            # diagnostic message (0x8002 is the ACK)
            print("UDS", req.hex(" "), "->", p[4:].hex(" "), flush=True)
            return p[4:]


def main():
    ip = sys.argv[1] if len(sys.argv) > 1 else "192.0.2.1"
    with socket.create_connection((ip, 13400), timeout=10) as s:
        print("DOIP connected", s.getsockname(), "->", s.getpeername(), flush=True)
        tx(s, frame(0x0005, struct.pack(">HB", SA, 0) + b"\0" * 4))
        _, p = rx(s)
        print("ROUTING ACTIVATION code 0x%02x" % p[4], flush=True)
        for r in REQUESTS:
            uds(s, r)


if __name__ == "__main__":
    main()
