# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""Judge a `xenvm/run.sh can` run from its serial log.

Prints the evidence (where DomZ's backends live, the UDS exchanges and the CAN
frames of every DomZ boot), then exactly one final line: PASS or FAIL: <reasons>.
Exit status 0 only on PASS.

The last boot in the log is the canary: its CAN backend is on another vcan, so
every request must go unanswered. The boots before it must answer everything,
and their SecurityAccess seed nonces must all differ.
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


def common(n, lines, errors):
    if not any(re.match(r"/local/domain/1/backend/virtio/\d+/0/type = \"virtio,device24\"", l)
               for l in lines):
        errors.append("boot %d: no virtio-can backend node under DomD" % n)
    if not any("diag task started" in l for l in lines):
        errors.append("boot %d: EDS did not start in DomZ" % n)


def judge(n, lines, errors):
    common(n, lines, errors)
    ex = uds(lines)
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
    if not dead and not wire(lines, "7E8"):
        errors.append("boot %d: no 0x7E8 frame on DomD's vcan0" % n)
    return seeds


def judge_canary(n, lines, errors):
    common(n, lines, errors)
    ex = uds(lines)
    if not ex:
        errors.append("canary boot %d: the tester sent nothing" % n)
    answered = [q for q, r in ex if r != "TIMEOUT"]
    if answered:
        errors.append("canary boot %d: answered %s with the backend on another bus" % (n, answered))
    if wire(lines, "7E8"):
        errors.append("canary boot %d: 0x7E8 frames on vcan0" % n)
    if not wire(lines, "7E0"):
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
            if l.startswith(("DomZ domid", "/local/domain/1/backend", "UDS ", "WIRE ", "DomZ  ")) \
                    or "SecurityAccess seeds" in l or "Booting Zephyr" in l or "can_virtio:" in l \
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
    print("PASS: DomZ (EDS on Zephyr + Xaloqi/zephyr-virtio-can) answered UDS over ISO-TP on DomD's "
          "vcan0 through virtio-can on %d boots (3E, 10 03, 22 F190, 27 01 x2), seed nonces all "
          "differ, and the canary boot (backend on vcan9) answered nothing" % len(seeds))
    return 0


if __name__ == "__main__":
    sys.exit(main())
