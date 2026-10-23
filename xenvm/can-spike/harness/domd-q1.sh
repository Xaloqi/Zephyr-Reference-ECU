#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Q1 in DomD: vcan0 + vhost-device-can (rust-vmm) + xen-vhost-frontend (Linaro),
# serving virtio-can (device 36) over virtio-mmio to a Linux 7.2 DomU, grant_usage=0.
cd /root
xenstore-write /local/pool/0/name Pool-0 /tool/xenconsoled/domid 1 \
  /local/domain/0/name Domain-0 /local/domain/0/domid 0 \
  /local/domain/1/name DomD /local/domain/1/domid 1
XENCONSOLED_TRACE=guest /usr/sbin/xenconsoled --pid-file=/run/xenconsoled.pid \
  --log=guest --log-dir=/var/log/xen/console
echo "=== versions"; uname -r; ./vhost-device-can --version 2>&1 | head -1; ls -l vhost-device-can xen-vhost-frontend Image-7.2 guest.cpio.gz | awk '{print $5, $9}'
ip link add dev vcan0 type vcan && ip link set vcan0 up
ip -d link show vcan0 | head -2
RUST_LOG=debug ./vhost-device-can --socket-path /tmp/can.sock --can-devices vcan0 > vdc.log 2>&1 &
VDC=$!
for i in $(seq 1 50); do [ -S /tmp/can.sock0 ] && break; sleep 0.1; done
ls -l /tmp/can.sock* 2>&1
# libxenstore (xl) also prefers this socket once it exists; the relay forwards to the
# same /dev/xen/xenbus it would otherwise open, so that is equivalent.
python3 xs-sock-relay.py > relay.log 2>&1 &
for i in $(seq 1 50); do [ -S /var/run/xenstored/socket ] && break; sleep 0.1; done
./xen-vhost-frontend --socket-path /tmp/ --foreign-mapping > xvf.log 2>&1 &
XVF=$!
sleep 1
python3 canpy.py dump vcan0 40 20 "DOMD RX" > domd-rx.log 2>&1 &
DUMP=$!
echo "=== linux-guest.cfg"; cat linux-guest.cfg
xl create -p linux-guest.cfg 2>&1 | grep -v "^Parsing config"
ID=$(xl domid LinuxCanGuest 2>/dev/null); echo "guest domid=$ID"
xenstore-ls -f /local/domain/1/backend/virtio/$ID 2>&1 | grep -E "/(base|irq|type|transport|grant_usage|state) "
sleep 3
echo "--- xen-vhost-frontend so far"; cat xvf.log
xl unpause LinuxCanGuest
LOG=/var/log/xen/console/guest-LinuxCanGuest.log
for i in $(seq 1 120); do grep -q "LGUEST READY" $LOG 2>/dev/null && break; sleep 1; done
echo "guest ready after ~${i}s"
python3 canpy.py send vcan0 321#DEADBEEF 18DAF110#0102030405 | sed 's/^/DOMD /'
for i in $(seq 1 60); do grep -q "LGUEST DONE" $LOG 2>/dev/null && break; sleep 1; done
wait $DUMP
xl list
echo "--- Linux guest console"; sed 's/\x1b\[[0-9;]*m//g' $LOG | grep -v '^$' | grep -E "LGUEST|virtio|can" | head -80
echo "--- DomD vcan0 capture"; cat domd-rx.log
echo "--- xen-vhost-frontend log"; cat xvf.log; echo "--- relay"; cat relay.log
echo "--- vhost-device-can log"; tail -40 vdc.log
xl destroy LinuxCanGuest 2>/dev/null
kill $XVF $VDC 2>/dev/null
