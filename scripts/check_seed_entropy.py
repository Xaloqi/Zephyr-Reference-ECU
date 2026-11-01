#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""Bench check: the first SecurityAccess seed differs from boot to boot.

Resets the ECU with ECUReset (0x11 01) N times and, after each boot, requests
the first level-1 seed (0x10 03, 0x27 01). It exits non-zero if two boots hand
out the same seed. A seed is 6 bytes of RNG output plus a 2-byte counter that
restarts at every boot, so the first seed differs per boot when the RNG is wired.

    python3 scripts/check_seed_entropy.py --channel "/dev/serial/by-id/<your adapter>@115200"

Needs python-can (pip install python-can) and a CAN adapter on the bench bus.
--interface socketcan --channel can0 works for a Linux CAN interface.
"""

import argparse
import sys
import time

import can


def parse_args():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--interface", default="slcan")
    p.add_argument("--channel", required=True,
                   help="e.g. /dev/serial/by-id/<adapter>@115200 (tty numbers move between boots)")
    p.add_argument("--bitrate", type=int, default=500000)
    p.add_argument("--request-id", type=lambda s: int(s, 16), default=0x7DF)
    p.add_argument("--response-id", type=lambda s: int(s, 16), default=0x7E8)
    p.add_argument("--boots", type=int, default=5)
    p.add_argument("--boot-wait", type=float, default=3.0,
                   help="seconds to wait after ECUReset before the next request")
    return p.parse_args()


class IsoTp:
    def __init__(self, bus, req_id, rsp_id):
        self.bus, self.req_id, self.rsp_id = bus, req_id, rsp_id

    def _frame(self, timeout):
        end = time.time() + timeout
        while time.time() < end:
            m = self.bus.recv(0.05)
            if m is not None and m.arbitration_id == self.rsp_id:
                return bytes(m.data)
        return None

    def _tx(self, data):
        self.bus.send(can.Message(arbitration_id=self.req_id,
                                  is_extended_id=False,
                                  data=data + b"\xAA" * (8 - len(data))))

    def request(self, payload, timeout=2.0):
        self._tx(bytes([len(payload)]) + payload)
        while True:
            f = self._frame(timeout)
            if f is None:
                return None
            kind = f[0] >> 4
            if kind == 0:
                resp = f[1:1 + (f[0] & 0xF)]
            elif kind == 1:
                total = ((f[0] & 0xF) << 8) | f[1]
                resp = f[2:8]
                self._tx(bytes([0x30, 0, 0]))
                while len(resp) < total:
                    c = self._frame(1.0)
                    if c is None:
                        return None
                    resp += c[1:8]
                resp = resp[:total]
            else:
                continue
            if len(resp) >= 3 and resp[0] == 0x7F and resp[2] == 0x78:
                continue   # responsePending
            return resp


def first_seed(tp):
    if tp.request(b"\x10\x03") is None:
        return None
    r = tp.request(b"\x27\x01")
    if r is None or r[:2] != b"\x67\x01":
        print(f"  unexpected 0x27 01 response: {r.hex(' ') if r else r}")
        return None
    return r[2:]


def main():
    a = parse_args()
    bus = can.Bus(interface=a.interface, channel=a.channel, bitrate=a.bitrate)
    tp = IsoTp(bus, a.request_id, a.response_id)
    seeds = []
    for n in range(1, a.boots + 1):
        seed = first_seed(tp)
        if seed is None:
            print(f"FAIL: boot {n}: no seed from the ECU")
            return 1
        print(f"boot {n}: first seed {seed.hex(' ')}")
        seeds.append(seed)
        if n < a.boots:
            if tp.request(b"\x11\x01") is None:
                print(f"FAIL: boot {n}: ECUReset got no response")
                return 1
            time.sleep(a.boot_wait)
    bus.shutdown()
    if len(set(seeds)) != len(seeds):
        print(f"FAIL: {len(seeds) - len(set(seeds))} repeated seed(s) across "
              f"{len(seeds)} boots; check the TRNG registration")
        return 1
    print(f"PASS: {len(seeds)} boots, {len(set(seeds))} distinct first seeds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
