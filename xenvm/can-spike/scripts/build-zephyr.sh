#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Inside the builder image, after ../../scripts/build.sh made /build/ws (Zephyr v4.4.1 + EDS).
# /module = the out-of-tree can_virtio driver module. Builds:
#   out/zephyr-can-test.bin  the driver test app (Q2)
#   out/zephyr-can-bcm.bin   ReferenceBCM, CAN variant, virtio-can + virtio-rng (Q3)
set -euo pipefail
W=/build/can-spike; mkdir -p $W/out
git config --global --add safe.directory '*'
cd /build/ws
west build -p always -b xenvm -s /src/xenvm/can-spike/test-app -d $W/obj-test -- \
  -DZEPHYR_EXTRA_MODULES=/module > $W/log-zephyr-test.txt 2>&1 || { tail -30 $W/log-zephyr-test.txt; exit 1; }
cp $W/obj-test/zephyr/zephyr.bin $W/out/zephyr-can-test.bin
grep -v '^CONFIG_STACK_CANARIES=' /src/prj.conf > $W/prj-xenvm-can.conf
west build -p always -b xenvm -s /src -d $W/obj-bcm -- -DZEPHYR_EXTRA_MODULES=/module \
  -DCONF_FILE=$W/prj-xenvm-can.conf -DDIAG_SKIP_CODEGEN=ON -DDIAG_ENTROPY_SEEDS=ON \
  -DEXTRA_CONF_FILE=boards/xenvm_can.conf -DEXTRA_DTC_OVERLAY_FILE=boards/xenvm_can.overlay \
  > $W/log-zephyr-bcm.txt 2>&1 || { tail -30 $W/log-zephyr-bcm.txt; exit 1; }
C=$W/obj-bcm/zephyr/.config
for s in PICOLIBC ENTROPY_VIRTIO CAN_VIRTIO REBOOT; do grep -qx "CONFIG_$s=y" $C || { echo "CONFIG_$s not y" >&2; exit 1; }; done
for s in STACK_CANARIES REQUIRES_STACK_CANARIES WATCHDOG TEST_RANDOM_GENERATOR CAN_LOOPBACK; do
  ! grep -qx "CONFIG_$s=y" $C || { echo "CONFIG_$s=y, expected off" >&2; exit 1; }; done
cp $W/obj-bcm/zephyr/zephyr.bin $W/out/zephyr-can-bcm.bin
ls -l $W/out/zephyr-can-*.bin
