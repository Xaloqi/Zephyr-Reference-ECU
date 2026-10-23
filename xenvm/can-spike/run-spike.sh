#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
#
# SPIKE (not merged): Zephyr virtio-can frontend in DomZ, option (A) of AGL SoDeV.
# Reuses the xenvm harness (../run.sh) and adds, in $XENVM_BUILD_DIR/can-spike:
#   rust-vmm vhost-device-can/-rng + Linaro xen-vhost-frontend (pinned, patched),
#   Linux 7.2.12 for the reference guest, the Zephyr images built with the driver.
#
#   xenvm/can-spike/run-spike.sh [build|q1|qa|q2|q3|q3-stress|all]
#   (the driver is Xaloqi/zephyr-virtio-can at VIRTIO_CAN_REV; VIRTIO_CAN_MODULE=<dir> uses a local checkout)
#
# Prerequisite: xenvm/run.sh has built the base harness (Xen, Linux, QEMU, rootfs, ws)
# from THIS branch (its linux.config adds CAN, vcan, XEN_VIRTIO, XEN_PRIVCMD_EVENTFD).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
BUILD=$(cd "${XENVM_BUILD_DIR:-$HERE/../build}" && pwd)
source "$HERE/versions.env"
IMAGE=xaloqi-zre-xenvm-builder:1
W=$BUILD/can-spike; mkdir -p $W
if [ -z "${VIRTIO_CAN_MODULE:-}" ]; then   # the pinned driver, unless a local checkout is given
  VIRTIO_CAN_MODULE=$W/zephyr-virtio-can
  [ -d $VIRTIO_CAN_MODULE/.git ] || git clone -q "$VIRTIO_CAN_URL" $VIRTIO_CAN_MODULE
  git -C $VIRTIO_CAN_MODULE fetch -q origin "$VIRTIO_CAN_REV" && git -C $VIRTIO_CAN_MODULE checkout -q "$VIRTIO_CAN_REV"
fi
MOD=$(cd "$VIRTIO_CAN_MODULE" && pwd)
U="$(id -u):$(id -g)"
c() { docker run --rm -v "$REPO":/src:ro -v "$BUILD":/build -v "$MOD":/module:ro -e GUEST_INIT -e XENVM_BOOT_TIMEOUT \
        "$IMAGE" bash -c "$1; rc=\$?; chown -R $U /build; exit \$rc"; }
H=/src/xenvm/can-spike/harness; O=/build/can-spike/out

build() {
  [ -f $BUILD/out/Image ] && [ -d $BUILD/ws/zephyr ] || { echo "FAIL: run xenvm/run.sh first (base harness)"; exit 2; }
  docker run --rm -v "$REPO":/src:ro -v "$W":/w "$RUST_IMAGE" \
    bash -c "/src/xenvm/can-spike/scripts/build-backends.sh; rc=\$?; chown -R $U /w; exit \$rc"
  [ -f $W/out/Image-7.2 ] || c /src/xenvm/can-spike/scripts/build-linux72.sh
  c /src/xenvm/can-spike/scripts/build-zephyr.sh
}
log() { sed 's/\x1b\[[0-9;]*m//g' $W/run-$1/serial.log | grep "P1|" | sed 's/^(XEN) DOM1: P1| //'; }
q1() {
  GUEST_INIT=$H/guest-init.sh c "/src/xenvm/can-spike/scripts/boot-spike.sh q1 $H/domd-q1.sh $H/canpy.py $H/xs-sock-relay.py \
    $H/linux-guest.cfg $O/vhost-device-can $O/xen-vhost-frontend $O/Image-7.2"
  log q1 | grep -E "LGUEST (RX|TX)|DOMD (RX|TX)" | tee $W/q1.txt
  n=$(grep -c -E "LGUEST RX can0 (321|18DAF110)|DOMD RX vcan0 (123|1ABCDE01|7FF) " $W/q1.txt || true)
  [ "$n" -ge 5 ] && echo "Q1 PASS: Linux 7.2 guest <-> DomD vcan0 over virtio-can, both ways" || echo "Q1 FAIL ($n/5 frames)"
}
qa() {
  [ -f $BUILD/out/qemu-dm-vu ] || c /src/xenvm/can-spike/scripts/build-qemu-vu.sh
  GUEST_INIT=$H/guest-init.sh c "/src/xenvm/can-spike/scripts/boot-spike.sh qa $H/domd-qa.sh $H/canpy.py \
    $H/linux-guest.cfg $O/vhost-device-can /build/out/qemu-dm-vu $O/Image-7.2"
  log qa | grep -E "attempt|qemu-dm-vu:|qemu alive" | tee $W/qa.txt
  echo "QA (option a) is expected to fail: see the campaign record"
}
q2() {
  c "/src/xenvm/can-spike/scripts/boot-spike.sh q2 $H/domd-q2.sh $H/canpy.py $H/xs-sock-relay.py /src/xenvm/harness/domz.cfg \
    $O/vhost-device-can $O/xen-vhost-frontend $O/zephyr-can-test.bin:zephyr-domz.bin"
  log q2 | grep -E "ZCAN|DOMD (RX|TX)" | tee $W/q2.txt
  grep -q "ZCAN RESULT PASS" $W/q2.txt && echo "Q2 PASS: driver test app against vhost-device-can" || echo "Q2 FAIL"
}
q3() { # [N boots incl. canary] [rounds]
  echo "N=${1:-3}; ROUNDS=${2:-1}" > $W/q3.env
  c "/src/xenvm/can-spike/scripts/boot-spike.sh q3 $H/domd-q3.sh $H/canpy.py $H/xs-sock-relay.py $H/isotp_probe.py \
    /src/xenvm/harness/domz.cfg $O/vhost-device-can $O/vhost-device-rng $O/xen-vhost-frontend \
    $O/zephyr-can-bcm.bin:zephyr-domz.bin /build/can-spike/q3.env"
  log q3 | grep -E "=== BOOT|^UDS |WIRE" | tee $W/q3.txt
  python3 - "$W/q3.txt" "${1:-3}" <<'PY'
import re, sys
txt = open(sys.argv[1]).read(); n = int(sys.argv[2])
boots = re.split(r"=== BOOT (\d+)[^\n]*\n", txt)[1:]
fails, nonces = [], []
for i in range(0, len(boots), 2):
    b, body = int(boots[i]), boots[i + 1]
    uds = re.findall(r"^UDS (.+?) -> (.+)$", body, re.M)
    if b == n:   # canary: the backend is on another bus
        if any(r != "TIMEOUT" for _, r in uds): fails.append("canary boot answered")
        continue
    want = {"3e 00": "7e 00", "10 03": "50 03 00 19 01 f4"}
    for q, r in uds:
        if q in want and r != want[q]: fails.append("boot %d: %s -> %s" % (b, q, r))
        if q == "22 f1 90" and len(r.split()) != 20: fails.append("boot %d: F190 -> %s" % (b, r))
        if q == "27 01":
            if not r.startswith("67 01"): fails.append("boot %d: 27 01 -> %s" % (b, r))
            else: nonces.append((b, " ".join(r.split()[2:8])))
    if not uds: fails.append("boot %d: no tester output" % b)
first = {}
for b, nn in nonces: first.setdefault(b, nn)
if len(set(first.values())) < len(first): fails.append("seed nonces repeat across boots: %s" % first)
print("Q3 %s: %d boots, %d seeds, first nonce per boot %s%s" % ("FAIL" if fails else "PASS", n - 1, len(nonces), first,
      "" if not fails else "; " + "; ".join(fails)))
PY
}
case "${1:-all}" in
  build) build ;; q1) q1 ;; qa) qa ;; q2) q2 ;; q3) q3 ;; q3-stress) q3 6 3 ;;
  all) build; q1; q2; q3 ;;
  *) echo "usage: $0 [build|q1|qa|q2|q3|q3-stress|all]"; exit 2 ;;
esac
