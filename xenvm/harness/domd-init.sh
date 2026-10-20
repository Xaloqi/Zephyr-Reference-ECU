#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# /init of DomD: a dom0less domain with capabilities = <1> (DOMAIN_CAPS_CONTROL),
# booted by Xen next to Dom0. It runs the toolstack (xl), the QEMU device model
# that backs DomZ's virtio devices, and the DoIP tester.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
/bin/busybox mkdir -p /proc /usr/local/bin; /bin/busybox mount -t proc proc /proc
/bin/busybox --install -s /usr/local/bin
mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts; mount -t devpts devpts /dev/pts; mount -t tmpfs tmpfs /run
mount -t xenfs xenfs /proc/xen
mkdir -p /var/run/xen /var/lib/xen /var/log/xen/console /run/xen /tmp
ldconfig 2>/dev/null; hostname domd; ip link set lo up
echo "P1-DOMD: kernel $(uname -r), /proc/xen/capabilities=[$(cat /proc/xen/capabilities)] (empty: not the initial domain)"
echo "P1-DOMD: cmdline: $(cat /proc/cmdline)"
/root/domd-test.sh 2>&1 | while IFS= read -r l; do echo "P1| $l"; done
xenstore-write /xaloqi-p1/done 1 && xenstore-chmod /xaloqi-p1 r1 && xenstore-chmod /xaloqi-p1/done r1
echo "P1-DOMD: done"
sleep 600
