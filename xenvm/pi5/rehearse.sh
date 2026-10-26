#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
#
# Rehearse the Pi 5 bench under QEMU, without the board: boot the xenvm CAN
# harness, and in DomD run xaloqi-can-bench (the script that ships in the SD
# image) through up, nucleo, domz, p2 x2, canary and down. See
# rehearse/domd-rehearse.sh for what is virtual here. Needs a build dir with a
# DomZ image built as ECU 1:
#   XENVM_BUILD_DIR=<dir> XENVM_CAN_ECU_INDEX=1 xenvm/run.sh can
#   xenvm/pi5/rehearse.sh <dir>
# Last line: PASS or FAIL: <reasons>. Timing printed here is TCG on a PC: it
# says nothing about the Pi.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BUILD=$(cd "${1:?usage: $0 <xenvm-build-dir>}" && pwd)
grep -q ' ecu=1 ' "$BUILD/out/zephyr-domz-can.stamp" 2>/dev/null \
  || { echo "FAIL: $BUILD has no DomZ image built as ECU 1 (XENVM_CAN_ECU_INDEX=1 xenvm/run.sh can)"; exit 1; }
F=/src/xenvm/pi5/meta-xaloqi-virtio-can/recipes-guests/xaloqi-domz-can/files
R=/src/xenvm/pi5/rehearse
docker run --rm -v "$REPO":/src:ro -v "$BUILD":/build \
  -e XENVM_CAN_DOMD_TEST=$R/domd-rehearse.sh \
  -e XENVM_CAN_EXTRA="$R/can_bridge.py $R/fake_nucleo.py $F/uds_timing.py $F/xaloqi-can-bench" \
  xaloqi-zre-xenvm-builder:1 \
  bash -c "/src/xenvm/scripts/boot.sh can; rc=\$?; chown -R $(id -u):$(id -g) /build; exit \$rc"
LOG=$BUILD/run-can/serial.log
cp "$LOG" "$BUILD/serial-rehearse.log"
python3 - "$LOG" <<'EOF'
import re, sys
lines = [re.sub(r"\x1b\[[0-9;]*m", "", l.rstrip("\r\n")) for l in open(sys.argv[1], errors="replace")]
lines = [l.split("P1| ", 1)[1] for l in lines if "P1| " in l]
steps, cur = {}, None
for l in lines:
    m = re.match(r"=== STEP xaloqi-can-bench (\S+)(?: (\S+))?", l)
    if m:
        cur = m.group(1) + ("-" + m.group(2) if m.group(2) else ""); steps[cur] = []
    elif l.startswith("=== END STEP"):
        cur = None
    elif cur:
        steps[cur].append(l)
want = ["up", "nucleo", "domz-can0", "p2-0", "p2-1", "canary", "down"]
errors = []
print("=" * 72)
for s in want:
    out = steps.get(s)
    if out is None:
        errors.append("step %s did not run" % s); continue
    verdict = next((l for l in reversed(out) if l.startswith(("PASS", "FAIL"))), "no verdict")
    for l in out:
        if l.startswith(("ISOTP", "UDS ", "P2 ", "DomZ-CAN domid")) or "UDS stack ready" in l or "/backend/virtio/" in l:
            print("  [%s] %s" % (s, l))
    print("%-10s %s" % (s, verdict))
    if not verdict.startswith("PASS"):
        errors.append("%s: %s" % (s, verdict))
if not any("REHEARSAL DONE" in l for l in lines):
    errors.append("DomD did not reach the end of the rehearsal")
print("=" * 72)
if errors:
    print("FAIL: " + "; ".join(errors)); sys.exit(1)
print("PASS: xaloqi-can-bench ran up, nucleo (stand-in), domz (virtio-can, ECU 1, across the "
      "bridged bus), p2 for both ECUs, canary (DomZ silent, stand-in answered) and down")
EOF
