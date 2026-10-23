#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Inside the builder image. Linux 7.2.12 (virtio_can is upstream from 7.2) for the reference guest.
set -euo pipefail
source /src/xenvm/can-spike/versions.env
W=/build/can-spike; mkdir -p $W/dl $W/src $W/out
f=$W/dl/linux-$LINUX72_VER.tar.xz
[ -f $f ] || wget -q -O $f $LINUX72_URL
echo "$LINUX72_SHA256  $f" | sha256sum -c --quiet
[ -d $W/src/linux-$LINUX72_VER ] || tar xf $f -C $W/src
M="make -C $W/src/linux-$LINUX72_VER ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O=$W/obj-linux72"
$M defconfig xen.config > $W/log-linux72.txt 2>&1
cat /src/xenvm/can-spike/scripts/linux72.config >> $W/obj-linux72/.config
$M olddefconfig >> $W/log-linux72.txt 2>&1
grep -qx CONFIG_CAN_VIRTIO_CAN=y $W/obj-linux72/.config || { echo "CONFIG_CAN_VIRTIO_CAN not set" >&2; exit 1; }
$M -j$(nproc) Image >> $W/log-linux72.txt 2>&1
cp $W/obj-linux72/arch/arm64/boot/Image $W/out/Image-7.2
