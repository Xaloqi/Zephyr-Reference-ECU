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
# Needs a build dir with a DomZ image built as ECU 1 (see rehearse.sh). Prints DomD's lines to
# <build-dir>/rehearse-<mode>.txt and the lines that matter here; there is no automatic verdict.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BUILD=$(cd "${1:?usage: $0 <xenvm-build-dir> load|teardown [N]}" && pwd)
MODE=${2:?load or teardown}
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
  *) echo "usage: $0 <xenvm-build-dir> load|teardown [N]"; exit 2 ;;
esac
docker run --rm -v "$REPO":/src:ro -v "$BUILD":/build \
  -e XENVM_BOOT_TIMEOUT=2400 -e XENVM_CAN_BOOTS=$CYCLES -e XENVM_CAN_ECU_INDEX=1 \
  -e XENVM_CAN_DOMD_TEST=$TEST -e XENVM_CAN_EXTRA="$EXTRA" \
  xaloqi-zre-xenvm-builder:1 \
  bash -c "/src/xenvm/scripts/boot.sh can; rc=\$?; chown -R $(id -u):$(id -g) /build; exit \$rc"
LOG=$BUILD/run-can/serial.log
sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -a 'P1| ' | sed 's/.*P1| //' > "$BUILD/rehearse-$MODE.txt"
grep -aE '^(=== |PASS|FAIL|P2 |panicked|thread .* panicked|\(null\)|TIMEOUT)' "$BUILD/rehearse-$MODE.txt" || true
echo "full DomD output: $BUILD/rehearse-$MODE.txt"
