#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# /init of the Linux 7.2 test guest (the known-good virtio-can frontend for Q1).
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/bin
/bin/busybox mkdir -p /proc /usr/local/bin; /bin/busybox mount -t proc proc /proc
/bin/busybox --install -s /usr/local/bin
mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev
echo "LGUEST: kernel $(uname -r)"
dmesg | grep -i -E "virtio|can" | sed 's/^/LGUEST dmesg: /'
ip -d link show can0 2>&1 | sed 's/^/LGUEST /'
ip link set can0 up 2>&1 | sed 's/^/LGUEST ip-up: /'
ip -d link show can0 2>&1 | head -3 | sed 's/^/LGUEST /'
python3 /root/canpy.py dump can0 20 20 "LGUEST RX" &
D=$!
sleep 1
echo "LGUEST READY"
sleep 6
python3 /root/canpy.py send can0 123#1122334455667788 1ABCDE01#AABB 7FF# | sed 's/^/LGUEST /'
wait $D
ip -s link show can0 | sed 's/^/LGUEST /'
echo "LGUEST DONE"
sleep 3
echo o > /proc/sysrq-trigger
sleep 30
