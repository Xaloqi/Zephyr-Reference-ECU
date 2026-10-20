#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Runs INSIDE the builder container. Boots Xen 4.22 under QEMU virt (GICv2,
# cortex-a57, TCG) with two boot-time domains:
#   Dom0  Linux, xenstore server only            (initramfs: rootfs + dom0-init.sh)
#   DomD  dom0less, capabilities = <1> (CONTROL)  (initramfs: rootfs + xl, QEMU DM,
#         DomZ image, domz.cfg, tester)
# DomD then creates DomZ (EDS) itself. The serial log is $RUN/serial.log.
set -euo pipefail
B=/build; OUT=$B/out; H=/src/xenvm/harness
RUN=$B/run; T=${XENVM_BOOT_TIMEOUT:-900}
rm -rf $RUN; mkdir -p $RUN

initrd() { # <name> <init> <payload files...>
  local name=$1 init=$2; shift 2
  local d=$RUN/$name.root
  cp -a $B/rootfs $d
  cp $init $d/init; chmod 755 $d/init
  mkdir -p $d/root; cp "$@" $d/root/
  (cd $d && find . | cpio -o -H newc -R 0:0 --quiet | gzip -1 > $RUN/$name.cpio.gz)
  rm -rf $d
}
initrd dom0 $H/dom0-init.sh $OUT/xs-seed-port
initrd domd $H/domd-init.sh $H/domd-test.sh $H/doip_probe.py $H/domz.cfg $OUT/qemu-dm $OUT/zephyr-domz.bin

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
