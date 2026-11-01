#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""UDS over ISO-TP with the kernel's CAN_ISOTP socket, Python stdlib only.
   isotp_probe.py IFACE [TX_ID RX_ID [fd]]   (default 7E0 7E8, physical addressing)
Prints 'UDS <req> -> <resp>' or 'UDS <req> -> TIMEOUT'.
With 'fd': CAN FD link layer (CANFD_MTU, TX_DL 64, BRS), and after the classic
requests two that only CAN FD carries in one frame / in FD frames: 22 with 4
DIDs (9 bytes: an FD Single Frame) and 22 with 33 DIDs (67 bytes: FF + CF at
TX_DL 64)."""
import errno, socket, struct, sys

SOL_CAN_ISOTP = 106          # SOL_CAN_BASE + CAN_ISOTP
CAN_ISOTP_OPTS = 1
CAN_ISOTP_TX_PADDING = 0x004
CAN_ISOTP_LL_OPTS = 5
CANFD_MTU, CANFD_BRS = 72, 0x01

iface = sys.argv[1]
tx_id = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0x7E0
rx_id = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0x7E8
fd = len(sys.argv) > 4 and sys.argv[4] == "fd"

s = socket.socket(socket.AF_CAN, socket.SOCK_DGRAM, socket.CAN_ISOTP)
# struct can_isotp_options: flags, frame_txtime, ext_address, txpad, rxpad, rx_ext_address
s.setsockopt(SOL_CAN_ISOTP, CAN_ISOTP_OPTS, struct.pack("=IIBBBB", CAN_ISOTP_TX_PADDING, 0, 0, 0xAA, 0, 0))
if fd:
    # struct can_isotp_ll_options: mtu, tx_dl, tx_flags
    s.setsockopt(SOL_CAN_ISOTP, CAN_ISOTP_LL_OPTS, struct.pack("=BBB", CANFD_MTU, 64, CANFD_BRS))
s.bind((iface, rx_id, tx_id))
s.settimeout(2.0)
def hx(b):
    """Hex; above 24 bytes "<first 3> ... (<len> B)", or "<pdu> x<n>" for a
    repeated pattern: Xen's console splits DomD lines at ~128 characters."""
    if len(b) <= 24:
        return " ".join("%02x" % x for x in b)
    for k in (2,):
        if (len(b) - 1) % k == 0 and b[1:] == b[1:1 + k] * ((len(b) - 1) // k):
            return "%02x %s x%d" % (b[0], " ".join("%02x" % x for x in b[1:1 + k]), (len(b) - 1) // k)
    return "%s ... (%d B)" % (" ".join("%02x" % x for x in b[:3]), len(b))
print("ISOTP %s tx 0x%03X rx 0x%03X%s" % (iface, tx_id, rx_id, " fd tx_dl 64" if fd else ""), flush=True)
reqs = ["3e 00", "10 03", "22 f1 90", "27 01", "27 01"]
if fd:
    # Then 22 F190 again (an FD Single Frame answer): EDS still answers after the
    # 67-byte request whose Flow Control the tester could not see.
    reqs += ["22" + " f1 90" * 4, "22" + " f1 90" * 33, "22 f1 90"]
for req in reqs:
    r = bytes.fromhex(req)
    try:
        s.send(r)
        resp = s.recv(4096)
        print("UDS %s -> %s" % (hx(r), hx(resp)), flush=True)
    except socket.timeout:
        print("UDS %s -> TIMEOUT" % hx(r), flush=True)
    except OSError as e:
        # The kernel's ISO-TP errors (ECOMM: no Flow Control within N_Bs; EILSEQ:
        # wrong sequence number) are unanswered requests too.
        print("ISOTP error on %s: %s" % (hx(r)[:20], errno.errorcode.get(e.errno, e.errno)), flush=True)
        print("UDS %s -> TIMEOUT" % hx(r), flush=True)
