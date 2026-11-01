# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""Judge a `xenvm/run.sh can` run from its serial log.

Prints the evidence (where DomZ's backends live, the UDS exchanges and the CAN
frames of every DomZ boot), then exactly one final line: PASS or FAIL: <reasons>.
Exit status 0 only on PASS.

The last boot in the log is the canary: its CAN backend is on another vcan, so
every request must go unanswered. The boots before it must answer everything,
and their SecurityAccess seed nonces must all differ.
CAN FD runs (XENVM_CAN_FD=1; the tester logs "fd tx_dl 64") judge the virtio-can
transport on the wire, per boot: the driver negotiated FD; EDS logged CAN FD
mode; DomZ's FD frames longer than 8 bytes are on DomD's vcan0 (out of DomZ);
and DomZ reacted to both FD-only requests, a 9-byte FD Single Frame (its
response's first frame follows it) and a 64-byte FD First Frame (its Flow
Control follows it), so FD frames went into DomZ.
At the ISO-TP level EDS v1.23-v1.26 (EDS#557) sends classic-format frames on its
FD channel: SFs up to 7 bytes, FF/CF and FC. A Linux CAN_ISOTP socket with
CANFD_MTU drops every frame that is not CANFD_MTU (net/can/isotp.c:
'if (skb->len != so->ll.mtu) return;'). So exactly FD_ANSWERED must be answered
and FD_EDS557 must time out. Anything else fails, including FD_EDS557 being
answered: then EDS#557 is fixed and these two lists must change.
"""
import re
import sys

PREFIX = re.compile(r"^(\(XEN\) DOM\d+: )?P1\| ")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
WANT = ("3e 00", "10 03", "22 f1 90", "27 01", "27 01")


def domd_lines(path):
    out = []
    with open(path, errors="replace") as f:
        for raw in f:
            line = ANSI.sub("", raw.replace("\r", "")).rstrip("\n")
            m = PREFIX.match(line)
            if m:
                out.append(line[m.end():])
    return out


def boots(lines):
    cur, res = None, {}
    for l in lines:
        m = re.match(r"=== BOOT (\d+)", l)
        if m:
            cur = int(m.group(1)); res[cur] = []
        elif l.startswith("=== END BOOT"):
            cur = None
        elif cur is not None:
            res[cur].append(l)
    return res


def uds(lines):
    return [m.groups() for m in (re.match(r"UDS (.+?) -> (.+)$", l) for l in lines) if m]


def wire(lines, can_id):
    return [l for l in lines if re.match(r"WIRE vcan0 %s \[" % can_id, l)]


def ids(n, lines, errors):
    """The (request, response) IDs this boot's tester used, from its 'ISOTP' line,
    and the IDs EDS in DomZ says it uses ('UDS stack ready: ... TX= PHYS='). The two
    must agree, or a tester and an image left on other IDs could pass vacuously."""
    t = [m.groups() for m in (re.match(r"ISOTP vcan0 tx 0x([0-9A-F]{3}) rx 0x([0-9A-F]{3})", l)
                              for l in lines) if m]
    if not t:
        errors.append("boot %d: no 'ISOTP' line from the tester" % n)
        return "7E0", "7E8"
    req, rsp = t[0]
    e = [m.groups() for m in (re.search(r"UDS stack ready: .* TX=0x([0-9A-F]{3}) PHYS=0x([0-9A-F]{3})", l)
                              for l in lines) if m]
    if e and e[0] != (rsp, req):
        errors.append("boot %d: tester uses 0x%s/0x%s, EDS in DomZ uses 0x%s/0x%s"
                      % (n, req, rsp, e[0][1], e[0][0]))
    if not e:
        errors.append("boot %d: EDS did not log its CAN IDs (UDS stack ready ... TX= PHYS=)" % n)
    return req, rsp


def common(n, lines, errors):
    if not any(re.match(r"/local/domain/1/backend/virtio/\d+/0/type = \"virtio,device24\"", l)
               for l in lines):
        errors.append("boot %d: no virtio-can backend node under DomD" % n)
    if not any("diag task started" in l for l in lines):
        errors.append("boot %d: EDS did not start in DomZ" % n)


# As isotp_probe.py prints them (over 24 bytes: "<SID> <pattern> x<n>").
FD_REQS = ("22" + " f1 90" * 4, "22 f1 90 x33")
# Answered with CAN FD frames only (FD Single Frames of 8..62 bytes).
FD_ANSWERED = ("22 f1 90", "27 01")
# Answered with a classic frame (SF <= 7 B, FF/CF, or EDS's FC): EDS#557.
FD_EDS557 = ("3e 00", "10 03") + FD_REQS


def is_fd_run(lines):
    return any(re.match(r"ISOTP vcan0 tx .* fd tx_dl 64", l) for l in lines)


def judge_fd(n, lines, ex, req, rsp, errors):
    if not any("can_virtio: virtio-can: classic +FD" in l for l in lines):
        errors.append("boot %d: virtio-can did not negotiate CAN FD" % n)
    if not any("CAN FD: " in l for l in lines):
        errors.append("boot %d: EDS did not log CAN FD mode (built without DIAG_CAN_FD?)" % n)
    if not any(re.match(r"WIRE vcan0 %s \[(1[2-9]|[2-6][0-9])\] FD" % rsp, l) for l in lines):
        errors.append("boot %d: no CAN FD frame longer than 8 bytes from DomZ (0x%s) on vcan0" % (n, rsp))
    w = [l for l in lines if l.startswith("WIRE vcan0 ")]
    for pat, then, what in ((r"WIRE vcan0 %s \[12\] FDBRS 00 09 22" % req, r"WIRE vcan0 %s \[8\] 10 " % rsp,
                             "the 9-byte FD Single Frame"),
                            (r"WIRE vcan0 %s \[64\] FDBRS 10 43 22" % req, r"WIRE vcan0 %s \[3\] 30 " % rsp,
                             "the 64-byte FD First Frame")):
        i = next((k for k, l in enumerate(w) if re.match(pat, l)), None)
        if i is None:
            errors.append("boot %d: the tester did not send %s" % (n, what))
        elif not (i + 1 < len(w) and re.match(then, w[i + 1])):
            errors.append("boot %d: DomZ did not react to %s (it did not reach DomZ?)" % (n, what))
    got = {}
    for q, r in ex:
        got.setdefault(q, []).append(r)
    for q in FD_ANSWERED:
        if any(r == "TIMEOUT" for r in got.get(q, ["TIMEOUT"])):
            errors.append("boot %d: %s unanswered (its answer is CAN FD only)" % (n, q))
    for q in FD_EDS557:
        rs = got.get(q)
        if rs is None:
            errors.append("boot %d: %s not sent" % (n, q.split()[0] + " ..."))
        elif any(r != "TIMEOUT" for r in rs):
            errors.append("boot %d: %s answered: EDS#557 looks fixed, update FD_EDS557 in check_can.py"
                          % (n, q[:20]))


def judge(n, lines, errors):
    common(n, lines, errors)
    req, rsp = ids(n, lines, errors)
    ex = uds(lines)
    if is_fd_run(lines):
        judge_fd(n, lines, ex, req, rsp, errors)
        # The rest of judge() is the classic exchange; EDS#557 times half of it out.
        if not any("SecurityAccess seeds from entropy device" in l for l in lines):
            errors.append("boot %d: EDS did not register the entropy seed callback" % n)
        return [r.split()[2:] for q, r in ex if q == "27 01" and r.startswith("67 01") and len(r.split()) == 10]
    reqs = tuple(q for q, _ in ex)
    if reqs[:len(WANT)] != WANT:
        errors.append("boot %d: tester sent %s, expected %s" % (n, list(reqs), list(WANT)))
    dead = [i for i, (_, r) in enumerate(ex) if r == "TIMEOUT"]
    if dead:
        i = dead[0]
        errors.append("boot %d: EDS stopped answering at request %d (%s); %d of %d unanswered"
                      % (n, i + 1, ex[i][0], len(dead), len(ex)))
    got = dict()
    seeds = []
    for q, r in ex:
        if r == "TIMEOUT":
            continue
        if q == "27 01":
            if r.startswith("67 01") and len(r.split()) == 10:
                seeds.append(r.split()[2:])
            else:
                errors.append("boot %d: 27 01 -> %s" % (n, r))
        else:
            got[q] = r
    if "3e 00" in got and got["3e 00"] != "7e 00":
        errors.append("boot %d: TesterPresent -> %s" % (n, got["3e 00"]))
    if "10 03" in got and not got["10 03"].startswith("50 03"):
        errors.append("boot %d: extended session -> %s" % (n, got["10 03"]))
    if "22 f1 90" in got and (not got["22 f1 90"].startswith("62 f1 90")
                              or len(got["22 f1 90"].split()) != 3 + 17):
        errors.append("boot %d: ReadDID F190 did not return 17 bytes" % n)
    if not any("SecurityAccess seeds from entropy device" in l for l in lines):
        errors.append("boot %d: EDS did not register the entropy seed callback" % n)
    # Answers must have crossed the bus in DomD, not come from anywhere else.
    if not dead and not wire(lines, rsp):
        errors.append("boot %d: no 0x%s frame on DomD's vcan0" % (n, rsp))
    return seeds


def judge_canary(n, lines, errors):
    common(n, lines, errors)
    req, rsp = ids(n, lines, errors)
    ex = uds(lines)
    if not ex:
        errors.append("canary boot %d: the tester sent nothing" % n)
    answered = [q for q, r in ex if r != "TIMEOUT"]
    if answered:
        errors.append("canary boot %d: answered %s with the backend on another bus" % (n, answered))
    if wire(lines, rsp):
        errors.append("canary boot %d: 0x%s frames on vcan0" % (n, rsp))
    if not wire(lines, req):
        errors.append("canary boot %d: the tester's frames are not on vcan0" % n)


def main():
    path = sys.argv[1]
    lines = domd_lines(path)
    errors = []
    b = boots(lines)
    print("=" * 72)
    print("Evidence from DomD (domid 1, dom0less, capabilities = <1>)")
    if len(sys.argv) > 2:
        print("  DomZ image built from  : " + sys.argv[2])
    if len(sys.argv) > 3:
        print("  DomD backends built from: " + sys.argv[3])
    for l in lines:
        if l.startswith(("xen_version", "virtio = ", "           \"backend")):
            print("  " + l)
    if len(b) < 3:
        errors.append("expected at least 2 boots and the canary, the log has %d boot(s)" % len(b))
    last = max(b) if b else 0
    seeds = {}
    for n in sorted(b):
        print("-" * 72)
        print("DomZ boot %d%s" % (n, " (canary: CAN backend on vcan9)" if n == last else ""))
        for l in b[n]:
            if l.startswith(("DomZ domid", "/local/domain/1/backend", "ISOTP ", "UDS ", "WIRE ", "DomZ  ")) \
                    or "UDS stack ready" in l or "SecurityAccess seeds" in l or "Booting Zephyr" in l or "can_virtio:" in l \
                    or "running without HW supervision" in l or "placeholder AES keys" in l \
                    or "ioreq not completed" in l:
                print("  " + l)
        if n == last:
            judge_canary(n, b[n], errors)
        else:
            seeds[n] = judge(n, b[n], errors)
    # EDS's 8-byte seed = a 6-byte nonce from the RNG callback + a 2-byte
    # sequence counter that restarts at every power cycle. The nonces must differ.
    nonces = [(n, " ".join(s[:6])) for n in sorted(seeds) for s in seeds[n]]
    seen = {}
    for n, x in nonces:
        if x in seen:
            errors.append("seed nonce %s repeated (boots %d and %d)" % (x, seen[x], n))
        seen.setdefault(x, n)
    print("-" * 72)
    for n in sorted(seeds):
        print("seeds boot %d: %s" % (n, " | ".join(" ".join(s) for s in seeds[n])))
    print("=" * 72)
    if errors:
        print("FAIL: " + "; ".join(errors))
        return 1
    fd = any(is_fd_run(b[n]) for n in b)
    print("PASS: DomZ (EDS on Zephyr + Xaloqi/zephyr-virtio-can) answered UDS over ISO-TP on DomD's "
          "vcan0 through virtio-can on %d boots (%s%s), seed nonces all "
          "differ, and the canary boot (backend on vcan9) answered nothing"
          % (len(seeds), "22 F190, 27 01 x2" if fd else "3E, 10 03, 22 F190, 27 01 x2", "; CAN FD: virtio-can negotiated FD and carried FD frames both ways; the ISO-TP answers EDS sends "
             "as classic frames (EDS#557: 3E, 10 03, 22 x4, 22 x33) timed out at the CANFD_MTU tester, as "
             "expected" if fd else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
