#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""UDS server response time (P2) on a real CAN bus, measured at a tester
interface, Python stdlib only.

    uds_timing.py IFACE REQ_ID RSP_ID [N] [GAP_MS] [CSV]
    e.g. uds_timing.py can1 7E0 7E8 1000 20 /var/log/xaloqi-can/p2-nucleo.csv

Method. One raw CAN socket on IFACE with CAN_RAW_RECV_OWN_MSGS and
SO_TIMESTAMPNS. For each sample it sends TesterPresent as a single frame
(02 3E 00, padded with AA) to REQ_ID. It then waits for the response on
RSP_ID, which must be 02 7E 00. A 7F 3E 78 (response pending) is counted
and the wait continues.
    t_req = kernel timestamp of the request's own-message echo. SocketCAN
            delivers it when the controller reports the frame sent, so it is
            the moment the request left IFACE's controller.
    t_rsp = kernel timestamp of the response frame's arrival on IFACE.
    P2    = t_rsp - t_req.
Both timestamps come from one clock, in one kernel, on one controller, so
neither ECU's clock or the tester's userspace scheduling enters. The figure
does include the bus time of the response frame (~0.1 ms at 500 kbit/s) and
the controller's receive-interrupt latency, the same for every ECU on the
bus, so the comparison between ECUs and paths holds. It is an upper bound on
the ECU's own P2.

Prints one summary line (n, timeouts, min, median, p95, p99, max in ms), then
PASS or FAIL against P2server_max (25 ms, diagnostics_config.yaml; XAQ_P2_MAX_MS
overrides it for the QEMU rehearsal only).
"""
import os, socket, struct, sys, time

SOL_CAN_RAW = 101
CAN_RAW_RECV_OWN_MSGS = 4
SO_TIMESTAMPNS = 35
FMT = "=IB3x8s"
# P2server_max of ReferenceBCM (diagnostics_config.yaml). XAQ_P2_MAX_MS overrides it
# only for the QEMU rehearsal, where TCG timing says nothing about the Pi.
P2_MAX_MS = float(os.environ.get("XAQ_P2_MAX_MS", "25"))


def pct(xs, p):
    if not xs:
        return float("nan")
    k = (len(xs) - 1) * p / 100.0
    lo = int(k)
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def recv(s):
    data, anc, _flags, _addr = s.recvmsg(16, socket.CMSG_SPACE(16))
    ts = None
    for lvl, typ, val in anc:
        if lvl == socket.SOL_SOCKET and typ == SO_TIMESTAMPNS:
            sec, nsec = struct.unpack("=qq", val[:16])
            ts = sec + nsec / 1e9
    cid, dlc, payload = struct.unpack(FMT, data)
    return cid & socket.CAN_SFF_MASK, payload[:dlc], ts


def main():
    iface, req, rsp = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16)
    n = int(sys.argv[4]) if len(sys.argv) > 4 else 1000
    gap = (float(sys.argv[5]) if len(sys.argv) > 5 else 20.0) / 1000.0
    csv = open(sys.argv[6], "w") if len(sys.argv) > 6 else None
    s = socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
    s.setsockopt(SOL_CAN_RAW, CAN_RAW_RECV_OWN_MSGS, 1)
    s.setsockopt(socket.SOL_SOCKET, SO_TIMESTAMPNS, 1)
    s.setsockopt(SOL_CAN_RAW, socket.CAN_RAW_FILTER,
                 struct.pack("=II", req, socket.CAN_SFF_MASK) + struct.pack("=II", rsp, socket.CAN_SFF_MASK))
    s.bind((iface,))
    frame = struct.pack(FMT, req, 8, bytes([0x02, 0x3E, 0x00, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA]))
    lat, timeouts, pending, bad, dup = [], 0, 0, 0, 0
    if csv:
        csv.write("sample,p2_ms\n")
    print("P2 %s req 0x%03X rsp 0x%03X n=%d gap=%.0f ms" % (iface, req, rsp, n, gap * 1000), flush=True)
    for i in range(n):
        # Anything on RSP_ID between two requests answered nobody: a second ECU on
        # the same response ID (an ID collision), or a late duplicate. Count it.
        s.setblocking(False)
        try:
            while True:
                if recv(s)[0] == rsp:
                    dup += 1
        except (BlockingIOError, socket.timeout):
            pass
        s.setblocking(True)
        s.send(frame)
        t_req = None
        deadline = time.monotonic() + 1.0
        got = None
        while time.monotonic() < deadline:
            s.settimeout(max(0.001, deadline - time.monotonic()))
            try:
                cid, d, ts = recv(s)
            except socket.timeout:
                break
            if cid == req and d[:3] == b"\x02\x3e\x00":
                t_req = ts
            elif cid == rsp and d[:4] == b"\x03\x7f\x3e\x78":
                pending += 1
            elif cid == rsp and d[:3] == b"\x02\x7e\x00":
                got = ts
                break
            elif cid == rsp:
                bad += 1
                break
        if got is None or t_req is None:
            timeouts += 1
            if csv:
                csv.write("%d,\n" % i)
        else:
            ms = (got - t_req) * 1000.0
            lat.append(ms)
            if csv:
                csv.write("%d,%.4f\n" % (i, ms))
        time.sleep(gap)
    lat.sort()
    line = ("P2 %s 0x%03X: n=%d answered=%d timeouts=%d pending=%d bad=%d unsolicited=%d "
            "min=%.3f median=%.3f p95=%.3f p99=%.3f max=%.3f ms"
            % (iface, rsp, n, len(lat), timeouts, pending, bad, dup,
               lat[0] if lat else float("nan"), pct(lat, 50), pct(lat, 95), pct(lat, 99),
               lat[-1] if lat else float("nan")))
    print(line, flush=True)
    ok = lat and timeouts == 0 and bad == 0 and dup == 0 and lat[-1] < P2_MAX_MS
    why = "another responder on 0x%03X (ID collision?): " % rsp if dup else ""
    print("PASS" if ok else "FAIL: %stimeouts=%d bad=%d unsolicited=%d max=%s ms (P2server_max %.0f ms)"
          % (why, timeouts, bad, dup, ("%.3f" % lat[-1]) if lat else "-", P2_MAX_MS), flush=True)
    return 0 if ok else 1


sys.exit(main())
