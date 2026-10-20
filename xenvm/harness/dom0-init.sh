#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# /init of Dom0. In SoDeV's default (Zephyr-Dom0) flavour Dom0 is the xenstore
# server and nothing else; this Dom0 does the same with upstream C xenstored.
# The toolstack privilege goes to DomD (domid 1): --priv-domid 1, the upstream
# counterpart of SoDeV's zephyr-xenlib CONFIG_XENSTORE_TOOLSTACK_DOMID.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
/bin/busybox mkdir -p /proc /usr/local/bin; /bin/busybox mount -t proc proc /proc
/bin/busybox --install -s /usr/local/bin
mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts; mount -t devpts devpts /dev/pts; mount -t tmpfs tmpfs /run
mount -t xenfs xenfs /proc/xen
mkdir -p /var/run/xen /var/lib/xen /var/log/xen /var/lib/xenstored /run/xen /tmp
ldconfig 2>/dev/null; hostname dom0
echo "P1-DOM0: kernel $(uname -r), /proc/xen/capabilities=[$(cat /proc/xen/capabilities)]"
/root/xs-seed-port 1 | sed 's/^/P1-DOM0: /'
/usr/sbin/xenstored --pid-file /run/xenstored.pid --master-domid 0 --priv-domid 1
echo "P1-DOM0: xenstored up (--master-domid 0 --priv-domid 1); Dom0 runs nothing else"
# Wait for DomD to finish, then power the machine off.
for i in $(seq 1 450); do
  [ "$(xenstore-read /xaloqi-p1/done 2>/dev/null)" = "1" ] && break
  sleep 2
done
echo "P1-DOM0: DomD finished (or timed out) after ~$((i * 2)) s, powering off"
echo o > /proc/sysrq-trigger
sleep 10
