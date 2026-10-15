#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""Download a signed MCUboot image to the ReferenceBCM over DoIP [EDS#425].

Runs 0x10 02, 0x27 01/02, 0x34, 0x36 xN, 0x37 (with CRC-32) and, with
--reset, 0x11 01, against the DoIP + secure-boot build (see
docs/secure-boot.md "Firmware update over DoIP"). It prints the time of each
phase and the 0x36 round-trip distribution, and exits non-zero on the first
negative response, naming it.

    python3 scripts/doip_flash.py build-app/zephyr/zephyr.signed.bin --reset

Standard library only, plus the free xaloqi-tester for the SecurityAccess
key (pip install xaloqi-tester). The key uses the placeholder AES keys this
ECU ships with unless XALOQI_SA_KEY_LEVEL_1 is set.
"""

import argparse
import socket
import statistics
import struct
import sys
import time
import zlib

from xaloqi.tester._security import derive_key

DOIP_VER = 0x02
T_ROUTING_REQ, T_ROUTING_RESP = 0x0005, 0x0006
T_DIAG, T_DIAG_ACK, T_DIAG_NACK = 0x8001, 0x8002, 0x8003

NRC_NAMES = {
    0x13: "incorrectMessageLengthOrInvalidFormat",
    0x22: "conditionsNotCorrect",
    0x24: "requestSequenceError",
    0x31: "requestOutOfRange",
    0x33: "securityAccessDenied",
    0x35: "invalidKey",
    0x72: "generalProgrammingFailure",
    0x73: "wrongBlockSequenceCounter",
    0x7E: "subFunctionNotSupportedInActiveSession",
    0x7F: "serviceNotSupportedInActiveSession",
}


class NegativeResponse(Exception):
    def __init__(self, sid, nrc):
        super().__init__("7F %02X %02X (%s)" % (sid, nrc, NRC_NAMES.get(nrc, "?")))
        self.sid, self.nrc = sid, nrc


class Doip:
    def __init__(self, host, port, tester, ecu, timeout):
        self.tester, self.ecu = tester, ecu
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock.settimeout(timeout)

    def close(self):
        self.sock.close()

    def _send(self, ptype, payload):
        self.sock.sendall(struct.pack(">BBHI", DOIP_VER, DOIP_VER ^ 0xFF,
                                      ptype, len(payload)) + payload)

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("ECU closed the connection")
            buf += chunk
        return buf

    def _recv(self):
        _, _, ptype, length = struct.unpack(">BBHI", self._recv_exact(8))
        return ptype, self._recv_exact(length)

    def activate(self):
        self._send(T_ROUTING_REQ, struct.pack(">HB4x", self.tester, 0x00))
        ptype, payload = self._recv()
        if ptype != T_ROUTING_RESP or payload[4] != 0x10:
            raise ConnectionError("routing activation refused: %s" % payload.hex())

    def request(self, uds, pending_timeout=150.0):
        """Send one UDS request; return the final response, skipping 0x78."""
        self._send(T_DIAG, struct.pack(">HH", self.tester, self.ecu) + uds)
        pendings = 0
        deadline = None
        while True:
            ptype, payload = self._recv()
            if ptype == T_DIAG_ACK:
                continue
            if ptype == T_DIAG_NACK:
                raise ConnectionError("diagnostic message NACK: %s" % payload.hex())
            if ptype != T_DIAG:
                continue
            resp = payload[4:]
            if len(resp) == 3 and resp[0] == 0x7F and resp[2] == 0x78:
                pendings += 1
                deadline = deadline or (time.monotonic() + pending_timeout)
                if time.monotonic() > deadline:
                    raise TimeoutError("response pending for over %.0f s" % pending_timeout)
                continue
            if resp[0] == 0x7F:
                raise NegativeResponse(resp[1], resp[2])
            if resp[0] != uds[0] + 0x40:
                raise ConnectionError("unexpected response %s to %s" % (resp.hex(), uds.hex()))
            self.last_pendings = pendings
            return resp


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("image", help="signed image (.bin, as written to the secondary slot)")
    ap.add_argument("--host", default="10.10.10.1")
    ap.add_argument("--port", type=int, default=13400)
    ap.add_argument("--tester-addr", type=lambda v: int(v, 0), default=0x0E00)
    ap.add_argument("--ecu-addr", type=lambda v: int(v, 0), default=0xE400)
    ap.add_argument("--address", type=lambda v: int(v, 0), default=0x00100000,
                    help="memoryAddress for 0x34: the image-1 partition offset")
    ap.add_argument("--reset", action="store_true", help="send 0x11 01 after 0x37")
    args = ap.parse_args()

    image = open(args.image, "rb").read()
    crc = zlib.crc32(image) & 0xFFFFFFFF
    print("image %s: %d bytes, CRC-32 0x%08X" % (args.image, len(image), crc))

    t0 = time.monotonic()
    ecu = Doip(args.host, args.port, args.tester_addr, args.ecu_addr, timeout=10.0)
    try:
        ecu.activate()
        ecu.request(b"\x10\x02")
        seed = ecu.request(b"\x27\x01")[2:]
        ecu.request(b"\x27\x02" + derive_key(seed, 1, quiet=True))
        print("session 0x02 + SecurityAccess L1: %.2f s" % (time.monotonic() - t0))

        t = time.monotonic()
        resp = ecu.request(b"\x34\x00\x44" + struct.pack(">II", args.address, len(image)))
        nlen = resp[1] >> 4
        max_block = int.from_bytes(resp[2:2 + nlen], "big")
        print("0x34 (erase behind %d x 0x78): %.2f s, maxNumberOfBlockLength %d"
              % (ecu.last_pendings, time.monotonic() - t, max_block))

        chunk = max_block - 2
        rtts = []
        t = time.monotonic()
        counter = 1
        for off in range(0, len(image), chunk):
            r0 = time.monotonic()
            ecu.request(bytes([0x36, counter]) + image[off:off + chunk])
            rtts.append(time.monotonic() - r0)
            counter = (counter + 1) & 0xFF
        dt = time.monotonic() - t
        rtts.sort()
        print("0x36: %d blocks in %.2f s (%.0f KiB/s); per request median %.2f ms, "
              "p99 %.2f ms, max %.2f ms" % (
                  len(rtts), dt, len(image) / 1024 / dt,
                  statistics.median(rtts) * 1e3,
                  rtts[int(len(rtts) * 0.99)] * 1e3, rtts[-1] * 1e3))

        t = time.monotonic()
        ecu.request(b"\x37" + struct.pack(">I", crc))
        print("0x37: positive in %.2f s" % (time.monotonic() - t))

        if args.reset:
            ecu.request(b"\x11\x01")
            print("0x11 01: positive")
        print("total %.2f s" % (time.monotonic() - t0))
    except NegativeResponse as e:
        print("REFUSED: %s after %.2f s" % (e, time.monotonic() - t0))
        return 2
    finally:
        ecu.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
