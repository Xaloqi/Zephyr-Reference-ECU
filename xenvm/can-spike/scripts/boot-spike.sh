#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Inside the builder image. The machine of ../../scripts/boot.sh, with a spike DomD:
#   boot-spike.sh <name> <domd script> <payload src[:name]>...
# GUEST_INIT=<file> also builds a Linux guest initramfs (payload name guest.cpio.gz).
# Log: /build/can-spike/run-<name>/serial.log
set -euo pipefail
B=/build; OUT=$B/out; H=/src/xenvm/harness; SH=/src/xenvm/can-spike/harness
NAME=$1; DOMD_RUN=$2; shift 2
RUN=$B/can-spike/run-$NAME; T=${XENVM_BOOT_TIMEOUT:-1800}
rm -rf $RUN; mkdir -p $RUN/payload
initrd() { # <name> <init> <dir with payload>
  local d=$RUN/$1.root
  cp -a $B/rootfs $d; cp $2 $d/init; chmod 755 $d/init
  mkdir -p $d/root; cp -a $3/. $d/root/
  (cd $d && find . | cpio -o -H newc -R 0:0 --quiet | gzip -1 > $RUN/$1.cpio.gz)
  rm -rf $d
}
if [ -n "${GUEST_INIT:-}" ]; then
  mkdir -p $RUN/gpayload; cp $SH/canpy.py $RUN/gpayload/
  initrd guest $GUEST_INIT $RUN/gpayload
  mv $RUN/guest.cpio.gz $RUN/payload/guest.cpio.gz
fi
cp $DOMD_RUN $RUN/payload/domd-run.sh
for f in "$@"; do src=${f%%:*}; dst=${f#*:}; [ "$dst" = "$f" ] && dst=$(basename $src); cp $src $RUN/payload/$dst; done
mkdir -p $RUN/d0; cp $OUT/xs-seed-port $RUN/d0/
initrd dom0 $H/dom0-init.sh $RUN/d0
initrd domd $SH/domd-init-q.sh $RUN/payload
QOPTS="-machine virt,virtualization=on,gic-version=2 -cpu cortex-a57 -m 4096 -smp 4 -display none -nic none"
D=$RUN/host.dtb
qemu-system-aarch64 $QOPTS -machine dumpdtb=$D >/dev/null 2>&1
hex() { printf %x $(stat -L -c %s $1); }
K=$OUT/Image
# Load addresses inside QEMU's 4 GiB (RAM starts at 0x40000000).
K0=0x49000000; R0=0x50000000; KD=0x80000000; RD=0x88000000
fdtput $D -p -t s /pl061@9030000 status disabled
fdtput $D -t s /chosen xen,xen-bootargs \
  "console=dtuart dtuart=/pl011@9000000 dom0_mem=512M dom0_max_vcpus=1 xsm=dummy bootscrub=0 loglvl=all guest_loglvl=all"
fdtput $D -t s /chosen xen,dom0-bootargs "console=hvc0 earlycon=xen rdinit=/init"
fdtput $D -t i /chosen '#address-cells' 2
fdtput $D -t i /chosen '#size-cells' 2
fdtput $D -c /chosen/module@$K0
fdtput $D -t s /chosen/module@$K0 compatible "multiboot,kernel" "multiboot,module"
fdtput $D -t x /chosen/module@$K0 reg 0 $K0 0 $(hex $K)
fdtput $D -c /chosen/module@$R0
fdtput $D -t s /chosen/module@$R0 compatible "multiboot,ramdisk" "multiboot,module"
fdtput $D -t x /chosen/module@$R0 reg 0 $R0 0 $(hex $RUN/dom0.cpio.gz)
# DomD, as SoDeV's u-boot scripts make it: a dom0less domain with xen,enhanced
# (xenstore) and capabilities = <DOMAIN_CAPS_CONTROL>; Linux with
# xen_privcmd.unrestricted=1 (privcmd is restricted outside the initial domain).
N=/chosen/domD
fdtput $D -c $N
fdtput $D -t s $N compatible "xen,domain"
fdtput $D -t i $N '#address-cells' 2
fdtput $D -t i $N '#size-cells' 2
fdtput $D -t i $N memory 0 1048576
fdtput $D -t i $N cpus 2
fdtput $D -t i $N vpl011 1
fdtput $D -t s $N xen,enhanced "enabled"
fdtput $D -t i $N capabilities 1
fdtput $D -c $N/module@$KD
fdtput $D -t s $N/module@$KD compatible "multiboot,kernel" "multiboot,module"
fdtput $D -t x $N/module@$KD reg 0 $KD 0 $(hex $K)
fdtput $D -t s $N/module@$KD bootargs "console=ttyAMA0 rdinit=/init xen_privcmd.unrestricted=1"
fdtput $D -c $N/module@$RD
fdtput $D -t s $N/module@$RD compatible "multiboot,ramdisk" "multiboot,module"
fdtput $D -t x $N/module@$RD reg 0 $RD 0 $(hex $RUN/domd.cpio.gz)
echo "--- host DTB /chosen/domD"; fdtget -p $D $N | sed 's/^/  /'
echo "  capabilities = $(fdtget $D $N capabilities)"

echo "[boot $(date +%H:%M:%S)] QEMU $(qemu-system-aarch64 --version | head -1 | awk '{print $4}'): Xen + Dom0 + DomD (timeout ${T}s)"
timeout $T qemu-system-aarch64 $QOPTS -serial mon:stdio -no-reboot \
  -kernel $OUT/xen -dtb $D \
  -device loader,file=$K,addr=$K0,force-raw=on \
  -device loader,file=$RUN/dom0.cpio.gz,addr=$R0,force-raw=on \
  -device loader,file=$K,addr=$KD,force-raw=on \
  -device loader,file=$RUN/domd.cpio.gz,addr=$RD,force-raw=on \
  < /dev/null > $RUN/serial.log 2>&1 || echo "[boot] QEMU exit status $? (124 = timeout)"
echo "[boot $(date +%H:%M:%S)] done, $(wc -l < $RUN/serial.log) lines in serial.log"
