#!/bin/bash
# Inside the builder image, after build.sh: the same QEMU 11.1.2 device model plus vhost-user
# (for backend option (a): vhost-user-test-device on Xen). Output /build/out/qemu-dm-vu.
set -euo pipefail
B=/build; ML=/usr/lib/aarch64-linux-gnu; X=$B/xen-tools/usr
cp -a $X/include/. /usr/include/aarch64-linux-gnu/; cp -a $X/lib/lib*.so* $ML/
mkdir -p $ML/pkgconfig
for pc in $X/lib/pkgconfig/*.pc; do
  sed -e "s|^libdir=.*|libdir=$ML|" -e "s|^includedir=.*|includedir=/usr/include/aarch64-linux-gnu|" \
      -e "s|^prefix=.*|prefix=/usr|" $pc > $ML/pkgconfig/$(basename $pc)
done
rm -rf $B/obj-qemu-vu; mkdir -p $B/obj-qemu-vu; cd $B/obj-qemu-vu
PKG_CONFIG_LIBDIR=$ML/pkgconfig:/usr/share/pkgconfig $B/src/qemu-11.1.2/configure \
  --cross-prefix=aarch64-linux-gnu- --target-list=aarch64-softmmu --prefix=/usr \
  --enable-xen --disable-kvm --disable-docs --disable-tools --disable-werror \
  --without-default-features --enable-fdt=system --disable-install-blobs \
  --enable-vhost-user > $B/log-qemu-vu.txt 2>&1
grep -E "CONFIG_VHOST_USER\b" config-host.h
ninja -j$(nproc) qemu-system-aarch64 >> $B/log-qemu-vu.txt 2>&1
aarch64-linux-gnu-strip -o $B/out/qemu-dm-vu qemu-system-aarch64
ls -l $B/out/qemu-dm-vu
