#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
#
# Add the virtio-can path (SoDeV CAN architecture A) to a sodev-demo-workspace-rpi
# checkout, for the Raspberry Pi 5 with the Waveshare 2-CH CAN HAT. Then build
# the SD image with SoDeV's own build.sh. See README.md next to this script.
#
#   xenvm/pi5/sodev-add.sh <sodev-workspace> <xenvm-build-dir>
#
# <xenvm-build-dir> must hold a DomZ image built as ECU 1:
#   XENVM_BUILD_DIR=<dir> XENVM_CAN_ECU_INDEX=1 xenvm/run.sh can
#
# What it changes in the workspace (nothing else):
#   meta-xaloqi-virtio-can/   the layer, with xenvm/patches/*, the harness scripts and
#                             the DomZ image copied in (build.sh mounts only the workspace)
#   rpi5-sodev.yaml           one line: the layer, in the domd component's layers
# Re-running it refreshes the copies; the yaml line is added once.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
XENVM=$(cd "$HERE/.." && pwd)
WS=$(cd "${1:?usage: $0 <sodev-workspace> <xenvm-build-dir>}" && pwd -P)
XB=$(cd "${2:?usage: $0 <sodev-workspace> <xenvm-build-dir>}" && pwd)
# The SoDeV commit this was built and checked against.
SODEV_REV=dc2755f603feb6166b489e2c3cc18eedf8e8f279

[ -f "$WS/rpi5-sodev.yaml" ] && [ -x "$WS/build.sh" ] || { echo "$WS is not a sodev-demo-workspace-rpi checkout" >&2; exit 1; }
HEAD=$(git -C "$WS" rev-parse HEAD)
[ "$HEAD" = "$SODEV_REV" ] || echo "WARNING: workspace is at $HEAD, this was checked against $SODEV_REV" >&2

BIN=$XB/out/zephyr-domz-can.bin STAMP=$XB/out/zephyr-domz-can.stamp
[ -f "$BIN" ] && [ -f "$STAMP" ] || { echo "no DomZ CAN image in $XB/out (run xenvm/run.sh can first)" >&2; exit 1; }
grep -q ' ecu=1 ' "$STAMP" || { echo "$BIN is not ECU 1: $(cat "$STAMP")" >&2
  echo "rebuild with XENVM_CAN_ECU_INDEX=1 xenvm/run.sh can" >&2; exit 1; }
# The image must be the one these sources build now (the same check run.sh makes).
. "$XENVM/versions.env"
APP=$(cd "$XENVM/.." && cat prj.conf CMakeLists.txt boards/xenvm_can.conf boards/xenvm_can.overlay src/*.c src/*.h | sha256sum | cut -c1-16)
WANT="zephyr=$ZEPHYR_REV eds=$EDS_REV virtio-can=$VIRTIO_CAN_REV ecu=1 app=$APP"
[ "$(cat "$STAMP")" = "$WANT" ] || { echo "stale DomZ image: built from [$(cat "$STAMP")], sources are [$WANT]" >&2; exit 1; }

L=$WS/meta-xaloqi-virtio-can
rm -rf "$L"
cp -r "$HERE/meta-xaloqi-virtio-can" "$L"
cp_v() { # <src> <dst dir>: copy and show the checksum, so the log says what went in
  install -D -m 0644 "$1" "$2/$(basename "$1")"
  echo "  $(sha256sum "$1" | cut -c1-16)  $(basename "$1") -> ${2#$WS/}"
}
echo "patches (verbatim from xenvm/patches/):"
cp_v "$XENVM/patches/vhost-device-c0bfee92.patch" "$L/recipes-virt/vhost-device/files"
for p in xen-vhost-frontend-a1e333c5 vireshk-vhost-abf24853 xen-sys-8a234c94; do
  cp_v "$XENVM/patches/$p.patch" "$L/recipes-virt/xen-vhost-frontend/files"
done
F=$L/recipes-guests/xaloqi-domz-can/files
echo "harness and DomZ image:"
for h in isotp_probe.py can_dump.py xs-sock-relay.py; do cp_v "$XENVM/harness/$h" "$F"; done
cp_v "$BIN" "$F"; cp_v "$STAMP" "$F"
echo "  DomZ: $(cat "$STAMP")"

python3 - "$WS/rpi5-sodev.yaml" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
line = '        - "../../meta-xaloqi-virtio-can"\n'
if line in s:
    print("rpi5-sodev.yaml: layer already listed"); sys.exit(0)
# The domd component (under components:) lists its layers; add ours after meta-xt-domz.
comp = s.index("\ncomponents:\n")
domd = s.index("\n  domd:\n", comp)
anchor = '        - "../../meta-rpi-sodev/meta-xt-common/meta-xt-domz"\n'
i = s.index(anchor, domd)
nxt = s.find("\n  domu:\n", domd)
if nxt != -1 and i > nxt:
    sys.exit("rpi5-sodev.yaml: meta-xt-domz not found in the domd component's layers")
i += len(anchor)
s = s[:i] + '        # Xaloqi: DomD owns the CAN HAT and serves DomZ-CAN over virtio-can\n' + line + s[i:]
open(p, "w").write(s)
print("rpi5-sodev.yaml: added ../../meta-xaloqi-virtio-can to the domd layers")
EOF
echo
echo "Now build (DomZ is SoDeV's stock DomZ; DomZ-CAN is started by xaloqi-can-bench):"
echo "  cd $WS && ./build.sh -z --ram=8g"
