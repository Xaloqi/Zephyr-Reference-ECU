# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""Judge a xenvm harness run from its serial log.

Prints the evidence (where DomZ's backend lives, the DoIP bytes of both DomZ
boots), then exactly one final line: PASS or FAIL: <reasons>. Exit status 0
only on PASS. A run with no DoIP bytes in its log is a FAIL.
"""
import re
import sys

PREFIX = re.compile(r"^(\(XEN\) DOM\d+: )?P1\| ")


def domd_lines(path):
    out = []
    with open(path, errors="replace") as f:
        for raw in f:
            line = raw.replace("\r", "").rstrip("\n")
            m = PREFIX.match(line)
            if m:
                out.append(line[m.end():])
    return out


def boots(lines):
    cur, res = None, {}
    for l in lines:
        m = re.match(r"=== BOOT (\d)$", l)
        if m:
            cur = int(m.group(1)); res[cur] = []
        elif l.startswith("=== END BOOT"):
            cur = None
        elif cur is not None:
            res[cur].append(l)
    return res


def judge(n, lines, errors):
    uds = [l for l in lines if l.startswith("UDS ")]
    def resp(req):
        return [l.split("-> ", 1)[1] for l in uds if l.startswith("UDS %s ->" % req)]
    if not any(l == "ROUTING ACTIVATION code 0x10" for l in lines):
        errors.append("boot %d: no routing activation success (0x10)" % n)
    if resp("3e 00") != ["7e 00"]:
        errors.append("boot %d: TesterPresent did not answer 7e 00" % n)
    did = resp("22 f1 90")
    if not did or not did[0].startswith("62 f1 90") or len(did[0].split()) != 3 + 17:
        errors.append("boot %d: ReadDID F190 did not return 17 bytes" % n)
    dsc = resp("10 03")
    if not dsc or not dsc[0].startswith("50 03"):
        errors.append("boot %d: extended session not entered" % n)
    seeds = [s.split()[2:] for s in resp("27 01") if s.startswith("67 01")]
    if len(seeds) != 2:
        errors.append("boot %d: expected two 27 01 seeds, got %d" % (n, len(seeds)))
    if not any("SecurityAccess seeds from entropy device" in l for l in lines):
        errors.append("boot %d: EDS did not register the entropy seed callback" % n)
    if not any(re.match(r"/local/domain/1/backend/virtio/\d+/0/type = \"virtio,device1\"", l) for l in lines):
        errors.append("boot %d: no virtio-net backend node under DomD" % n)
    return seeds


def main():
    path = sys.argv[1]
    lines = domd_lines(path)
    errors = []
    b = boots(lines)
    print("=" * 72)
    print("Evidence from DomD (domid 1, dom0less, capabilities = <1>)")
    for l in lines:
        if l.startswith(("xen_version", "Name ", "Domain-0", "DomD ", "virtio = ", "           \"backend")):
            print("  " + l)
    seeds = {}
    for n in (1, 2):
        if n not in b:
            errors.append("boot %d: missing" % n)
            continue
        print("-" * 72)
        print("DomZ boot %d" % n)
        for l in b[n]:
            if l.startswith(("DomZ domid", "/local/domain/1/backend", "--- QEMU device model",
                             "DOIP ", "ROUTING", "UDS ")) or "SecurityAccess seeds" in l \
                    or "Booting Zephyr" in l or "running without HW supervision" in l \
                    or "placeholder AES keys" in l:
                print("  " + l)
        seeds[n] = judge(n, b[n], errors)
    # EDS's 8-byte seed = a 6-byte nonce from the RNG callback + a 2-byte
    # sequence counter that restarts at every power cycle (core/
    # uds_security_algo.c). The counter repeats across boots by design, so
    # the nonces are what must differ.
    if len(seeds) == 2 and len(seeds[1]) == 2 and len(seeds[2]) == 2:
        nonce = {n: [s[:6] for s in seeds[n]] for n in (1, 2)}
        for i in range(2):
            if nonce[1][i] == nonce[2][i]:
                errors.append("seed %d nonce is identical on both boots (%s)" % (i + 1, " ".join(nonce[1][i])))
        if nonce[1][0] == nonce[1][1] or nonce[2][0] == nonce[2][1]:
            errors.append("a boot repeated its own seed nonce")
        print("-" * 72)
        for n in (1, 2):
            print("seeds boot %d: %s" % (n, " | ".join(" ".join(s) for s in seeds[n])))
    print("=" * 72)
    if errors:
        print("FAIL: " + "; ".join(errors))
        return 1
    print("PASS: DomD (dom0less, DOMAIN_CAPS_CONTROL) created DomZ and served its virtio-net/rng "
          "with QEMU; DoIP routing activation, 3E, 22 F190, 10 03, 27 01 x2 answered on two boots; "
          "seed nonces differ between boots")
    return 0


if __name__ == "__main__":
    sys.exit(main())
