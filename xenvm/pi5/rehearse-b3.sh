#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
#
# The two extra QEMU rehearsals of the Pi 5 bench (B3 prep), in the harness of rehearse.sh:
#   rehearse-b3.sh <xenvm-build-dir> load        the DomD load tool (bench/xaloqi-domd-load): sent as
#                                                base64 + sha256, start/check/stop/cell with the p2 tool
#   rehearse-b3.sh <xenvm-build-dir> teardown [N]  N (default 2) create/destroy cycles of DomZ-CAN, then
#                                                destroy of a domain that never ran: xen-vhost-frontend's
#                                                output and Xen's view of the domain after each
# B4 (image prep, 2026-11-11), same harness:
#   rehearse-b3.sh <xenvm-build-dir> b4          every B4 cell with the baked-in tools (placement printed, the pin
#                                                check stopping a cell on purpose, the group runner), as on the Pi
#   rehearse-b3.sh <xenvm-build-dir> reset [N]   N (default 6) paused-then-destroyed DomZ-CAN cases: frontend
#                                                panics and dying domains per case (the reset() fix, issue A)
#   XENVM_DOMD_WAIT=<seconds> raises DomD's 900 s cap (b4 needs about 2400).
#   BEFORE_BIN=<old vhost-device-can> rehearse-b3.sh <xenvm-build-dir> idle [SECS]
#                                                vhost-device-can CPU with an idle bus, before and after the
#                                                reader-poll patch (default 80 s each)
# Needs a build dir with a DomZ image built as ECU 1 (see rehearse.sh). Prints DomD's lines to
# <build-dir>/rehearse-<mode>.txt and the lines that matter here; there is no automatic verdict.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BUILD=$(cd "${1:?usage: $0 <xenvm-build-dir> load|teardown|b4|reset|idle [N]}" && pwd)
MODE=${2:?load, teardown, b4, reset or idle}
grep -q ' ecu=1 ' "$BUILD/out/zephyr-domz-can.stamp" 2>/dev/null \
  || { echo "FAIL: $BUILD has no DomZ image built as ECU 1 (XENVM_CAN_ECU_INDEX=1 xenvm/run.sh can)"; exit 1; }
F=/src/xenvm/pi5/meta-xaloqi-virtio-can/recipes-guests/xaloqi-domz-can/files
R=/src/xenvm/pi5/rehearse
EXTRA="$R/can_bridge.py $F/uds_timing.py $F/isotp_burst.py $F/xaloqi-can-bench"
case $MODE in
  load)
    # The file as the console delivers it: base64 and a sha256, checked in DomD.
    mkdir -p "$BUILD/extra"
    base64 -w0 "$HERE/bench/xaloqi-domd-load" > "$BUILD/extra/xaloqi-domd-load.b64"; echo >> "$BUILD/extra/xaloqi-domd-load.b64"
    echo "$(sha256sum < "$HERE/bench/xaloqi-domd-load" | cut -d' ' -f1)  xaloqi-domd-load" > "$BUILD/extra/xaloqi-domd-load.sha"
    TEST=$R/domd-load-rehearse.sh; CYCLES=0
    EXTRA="$EXTRA $R/fake_nucleo.py /src/xenvm/pi5/bench/xaloqi-domd-load /build/extra/xaloqi-domd-load.b64 /build/extra/xaloqi-domd-load.sha" ;;
  teardown)
    TEST=$R/domd-teardown.sh; CYCLES=${3:-2} ;;
  b4)
    B=/src/xenvm/pi5/bench
    TEST=$R/domd-b4-rehearse.sh; CYCLES=0
    EXTRA="$EXTRA $R/fake_nucleo.py $B/xaloqi-domd-load $B/xaloqi-b3-group $B/xaloqi-proc-cpu" ;;
  reset)
    TEST=$R/domd-reset-proof.sh; CYCLES=${3:-6} ;;
  idle)
    : "${BEFORE_BIN:?set BEFORE_BIN to the vhost-device-can from before the reader-poll patch}"
    mkdir -p "$BUILD/extra"; cp "$BEFORE_BIN" "$BUILD/extra/vhost-device-can-before"
    TEST=$R/domd-idle-compare.sh; CYCLES=${3:-80}
    EXTRA="/src/xenvm/pi5/bench/xaloqi-proc-cpu /build/extra/vhost-device-can-before" ;;
  *) echo "usage: $0 <xenvm-build-dir> load|teardown|b4|reset|idle [N]"; exit 2 ;;
esac
docker run --rm -v "$REPO":/src:ro -v "$BUILD":/build \
  -e XENVM_BOOT_TIMEOUT=$(( ${XENVM_DOMD_WAIT:-900} + 1500 )) -e XENVM_DOMD_WAIT=${XENVM_DOMD_WAIT:-900} -e XENVM_CAN_BOOTS=$CYCLES -e XENVM_CAN_ECU_INDEX=1 \
  -e XENVM_CAN_DOMD_TEST=$TEST -e XENVM_CAN_EXTRA="$EXTRA" \
  xaloqi-zre-xenvm-builder:1 \
  bash -c "/src/xenvm/scripts/boot.sh can; rc=\$?; chown -R $(id -u):$(id -g) /build; exit \$rc"
LOG=$BUILD/run-can/serial.log
sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -a 'P1| ' | sed 's/.*P1| //' > "$BUILD/rehearse-$MODE.txt"
grep -aE '^(=== |PASS|FAIL|P2 |RESULT|SUMMARY|DomZ-CAN vCPU|DomZ-CAN domid|cell rc|panicked|thread .* panicked|\(null\)|TIMEOUT|vhost-device-can|XAQ_DOMZ)' "$BUILD/rehearse-$MODE.txt" || true
echo "full DomD output: $BUILD/rehearse-$MODE.txt"
