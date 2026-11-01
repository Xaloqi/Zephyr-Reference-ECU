#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""ISO-TP burst traffic and frame loss on a CAN (FD) bus, Python stdlib only.

    isotp_burst.py link TX_IF RX_IF [N] [SIZE] [CSV]
        N messages of SIZE bytes (default 500 x 4000) from an ISO-TP socket on
        TX_IF (ID 0x6F0) to one on RX_IF (ID 0x6F0 -> FC on 0x6F8). The receiver
        advertises BS 0 and STmin 0, so the sender bursts every CF back to back.
    isotp_burst.py ecu IFACE REQ_ID RSP_ID [N] [DIDS] [CSV]
        N ReadDataByIdentifier requests with DIDS x F190 (default 200 x 33: a
        67-byte request, multi-frame at TX_DL 64) to an ECU, and its multi-frame
        response (19 bytes per DID) back.

CAN FD by default: CANFD_MTU, TX_DL 64 and BRS on what this tool sends. XAQ_FD=0
gives classic CAN (TX_DL 8), the comparison row.

Counted, separately, because they fail differently:
  message loss  ISO-TP messages that never arrived intact (timeout, short,
                wrong content). Each 'link' message carries a sequence number
                and a pattern, so a lost, repeated or reordered one shows.
  frame loss    ISO-TP data frames seen on the receiving interface (raw socket,
                one per frame) against the frames the sender put on the wire,
                for the burst's CAN ID. The sent ones are counted on TX_IF: a
                raw socket there gets every frame this host sends, flagged
                MSG_DONTROUTE, and on a real controller (IFF_ECHO) only once the
                frame is on the bus. On one bus,
                with no error frames, the two counts are equal; a difference is
                frames the receiving controller or its driver dropped.
  kernel        the receiving interface's rx_dropped, rx_over_errors, rx_errors
                and bus-error counters (ip -s), before and after.
For 'ecu' the sender is the ECU: the tool counts the response's FF + CFs on
IFACE and checks them against FF_DL at the RX_DL the FF set.

Prints one summary line, then PASS (no message, frame or kernel-counted loss) or
FAIL: <reasons>. A CSV, if given, gets one row per message.
"""
import errno, os, socket, struct, subprocess, sys, time

SOL_CAN_ISOTP, CAN_ISOTP_OPTS, CAN_ISOTP_RECV_FC, CAN_ISOTP_LL_OPTS = 106, 1, 2, 5
CAN_ISOTP_TX_PADDING = 0x004
SOL_CAN_RAW, CAN_RAW_FD_FRAMES = 101, 5
CANFD_MTU, CAN_MTU, CANFD_BRS = 72, 16, 0x01
FD = os.environ.get("XAQ_FD", "1") != "0"
LINK_TX, LINK_FC = 0x6F0, 0x6F8


def isotp_sock(iface, rx_id, tx_id, timeout):
    s = socket.socket(socket.AF_CAN, socket.SOCK_DGRAM, socket.CAN_ISOTP)
    # can_isotp_options: flags, frame_txtime, ext_address, txpad, rxpad, rx_ext_address
    s.setsockopt(SOL_CAN_ISOTP, CAN_ISOTP_OPTS, struct.pack("=IIBBBB", CAN_ISOTP_TX_PADDING, 0, 0, 0xAA, 0, 0))
    # can_isotp_fc_options: bs, stmin, wftmax -> BS 0, STmin 0: back-to-back CFs.
    s.setsockopt(SOL_CAN_ISOTP, CAN_ISOTP_RECV_FC, struct.pack("=BBB", 0, 0, 0))
    if FD:
        # can_isotp_ll_options: mtu, tx_dl, tx_flags
        s.setsockopt(SOL_CAN_ISOTP, CAN_ISOTP_LL_OPTS, struct.pack("=BBB", CANFD_MTU, 64, CANFD_BRS))
    s.bind((iface, rx_id, tx_id))
    s.settimeout(timeout)
    return s


def raw_sock(iface):
    s = socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
    s.setsockopt(SOL_CAN_RAW, CAN_RAW_FD_FRAMES, 1)
    s.bind((iface,))
    s.setblocking(False)
    return s


def drain(s, ids):
    """Read every pending frame; return (id, len, data, is_fd, local) for ids.
    local: MSG_DONTROUTE, i.e. sent by a socket on this host."""
    out = []
    while True:
        try:
            fr, anc, msgflags, _ = s.recvmsg(CANFD_MTU, 0)
        except BlockingIOError:
            return out
        cid = struct.unpack_from("=I", fr)[0] & socket.CAN_SFF_MASK
        ln = fr[4]
        if cid in ids:
            out.append((cid, ln, bytes(fr[8:8 + ln]), len(fr) == CANFD_MTU, bool(msgflags & socket.MSG_DONTROUTE)))


def xfer(send, data, recv):
    """One ISO-TP exchange. Linux reports reassembly errors on recv() with an
    errno (EILSEQ: wrong sequence number, i.e. a CF went missing; ECOMM: no
    Flow Control). They are losses, not crashes: (None, errno name)."""
    try:
        send(data)
        return recv(8192), None
    except socket.timeout:
        return None, "timeout"
    except OSError as e:
        return None, errno.errorcode.get(e.errno, str(e.errno))


def counters(iface):
    try:
        t = subprocess.run(["ip", "-s", "-d", "link", "show", iface], capture_output=True, text=True).stdout
    except OSError:
        return {}
    c = {}
    ls = t.splitlines()
    for i, l in enumerate(ls):
        w = l.split()
        if w[:1] == ["RX:"] and i + 1 < len(ls):
            v = ls[i + 1].split()
            c.update({"rx_errors": int(v[2]), "rx_dropped": int(v[3]), "rx_over": int(v[4])})
        if "bus-errors" in w and i + 1 < len(ls):
            v = ls[i + 1].split()
            c.update({"bus_errors": int(v[w.index("bus-errors")])})
    return c


def delta(a, b):
    return {k: b[k] - a.get(k, 0) for k in b}


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p / 100.0 * (len(v) - 1))))] if v else float("nan")


def link(tx_if, rx_if, n, size, csv):
    rx = isotp_sock(rx_if, LINK_TX, LINK_FC, 2.0)
    tx = isotp_sock(tx_if, LINK_FC, LINK_TX, 2.0)
    echo = raw_sock(tx_if)
    seen = raw_sock(rx_if)
    c0 = counters(rx_if)
    lost, bad, lat, frames_tx, frames_rx, rows, errs = 0, 0, [], 0, 0, [], {}
    for i in range(n):
        body = struct.pack(">I", i) + bytes((i + k) & 0xFF for k in range(size - 4))
        t0 = time.monotonic()
        got, err = xfer(tx.send, body, rx.recv)
        dt = (time.monotonic() - t0) * 1000.0
        ok = got == body
        if got is None:
            lost += 1
        elif not ok:
            bad += 1
        else:
            lat.append(dt)
        etx = sum(1 for f in drain(echo, {LINK_TX}) if f[4])
        # On RX_IF a 0x6F0 frame came off the wire (or a bridge): the sender's
        # socket is on TX_IF, so its local copies appear on TX_IF only.
        r = drain(seen, {LINK_TX})
        frames_tx += etx
        frames_rx += len(r)
        if err:
            errs[err] = errs.get(err, 0) + 1
        rows.append((i, "ok" if ok else (err if got is None else "bad"), "%.3f" % dt, etx, len(r)))
    time.sleep(0.2)
    frames_tx += sum(1 for f in drain(echo, {LINK_TX}) if f[4])
    frames_rx += len(drain(seen, {LINK_TX}))
    kd = delta(c0, counters(rx_if))
    if csv:
        with open(csv, "w") as f:
            f.write("msg,result,ms,frames_tx,frames_rx\n")
            for row in rows:
                f.write(",".join(str(x) for x in row) + "\n")
    print("burst link %s->%s %s: n=%d size=%d  messages lost=%d bad=%d  frames tx=%d rx=%d lost=%d  "
          "msg ms median=%.2f p99=%.2f max=%.2f  errors %s  kernel %s"
          % (tx_if, rx_if, "FD tx_dl 64 BRS" if FD else "classic", n, size, lost, bad, frames_tx, frames_rx,
             frames_tx - frames_rx, pct(lat, 50), pct(lat, 99), max(lat) if lat else float("nan"), errs, kd))
    why = []
    if lost or bad:
        why.append("%d message(s) lost, %d bad" % (lost, bad))
    if frames_tx == 0:
        why.append("no own-message echoes on %s: frame count vacuous" % tx_if)
    elif frames_tx != frames_rx:
        why.append("%d frame(s) sent, %d received on %s" % (frames_tx, frames_rx, rx_if))
    if any(kd.get(k, 0) for k in ("rx_dropped", "rx_over", "rx_errors", "bus_errors")):
        why.append("kernel counters moved on %s: %s" % (rx_if, kd))
    return why


def ecu(iface, req, rsp, n, dids, csv):
    s = isotp_sock(iface, rsp, req, 2.0)
    seen = raw_sock(iface)
    c0 = counters(iface)
    q = b"\x22" + b"\xF1\x90" * dids
    want_len = 1 + 19 * dids
    lost, bad, lat, frame_short, rows, errs = 0, 0, [], 0, [], {}
    for i in range(n):
        t0 = time.monotonic()
        got, err = xfer(s.send, q, s.recv)
        dt = (time.monotonic() - t0) * 1000.0
        fr = [f for f in drain(seen, {rsp})]
        # The response's frames: FF (sets RX_DL = its length) then CFs. With FF_DL
        # bytes, 6 in the FF and RX_DL-1 per CF, the CF count is known.
        exp = None
        if fr and (fr[0][2][0] >> 4) == 1:
            ffdl = ((fr[0][2][0] & 0x0F) << 8) | fr[0][2][1]
            rxdl = fr[0][1]
            exp = 1 + -(-(ffdl - (rxdl - 2)) // (rxdl - 1))
            if len(fr) < exp:
                frame_short += exp - len(fr)
        ok = got is not None and got[:3] == b"\x62\xF1\x90" and len(got) == want_len
        if got is None:
            lost += 1
        elif not ok:
            bad += 1
        else:
            lat.append(dt)
        if err:
            errs[err] = errs.get(err, 0) + 1
        rows.append((i, "ok" if ok else (err if got is None else "bad"), "%.3f" % dt, len(fr), exp))
    kd = delta(c0, counters(iface))
    if csv:
        with open(csv, "w") as f:
            f.write("req,result,ms,rsp_frames,rsp_frames_expected\n")
            for row in rows:
                f.write(",".join(str(x) for x in row) + "\n")
    print("burst ecu %s 0x%03X->0x%03X %s: n=%d dids=%d (req %d B, rsp %d B)  lost=%d bad=%d  "
          "response frames missing=%d  ms median=%.2f p99=%.2f max=%.2f  errors %s  kernel %s"
          % (iface, req, rsp, "FD tx_dl 64 BRS" if FD else "classic", n, dids, len(q), want_len, lost, bad,
             frame_short, pct(lat, 50), pct(lat, 99), max(lat) if lat else float("nan"), errs, kd))
    why = []
    if lost or bad:
        why.append("%d request(s) unanswered, %d wrong" % (lost, bad))
    if frame_short:
        why.append("%d response frame(s) missing on %s" % (frame_short, iface))
    if any(kd.get(k, 0) for k in ("rx_dropped", "rx_over", "rx_errors", "bus_errors")):
        why.append("kernel counters moved on %s: %s" % (iface, kd))
    return why


def main(a):
    if len(a) >= 3 and a[0] == "link":
        why = link(a[1], a[2], int(a[3]) if len(a) > 3 else 500, int(a[4]) if len(a) > 4 else 4000,
                   a[5] if len(a) > 5 else None)
    elif len(a) >= 4 and a[0] == "ecu":
        why = ecu(a[1], int(a[2], 16), int(a[3], 16), int(a[4]) if len(a) > 4 else 200,
                  int(a[5]) if len(a) > 5 else 33, a[6] if len(a) > 6 else None)
    else:
        print(__doc__)
        return 2
    print("FAIL: " + "; ".join(why) if why else "PASS")
    return 1 if why else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
