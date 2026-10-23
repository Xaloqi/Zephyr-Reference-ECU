#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Q3 in DomD: EDS (ReferenceBCM, CAN) in DomZ on virtio-can, served by
# vhost-device-can (vcan0) + vhost-device-rng through xen-vhost-frontend.
# Boots 1..N-1: UDS over ISO-TP from DomD, ROUNDS times per boot. Boot N (canary):
# the CAN backend is attached to vcan9, the tester stays on vcan0, so it must get nothing.
# N and ROUNDS come from /root/q3.env (default N=3, ROUNDS=1).
cd /root
N=3; ROUNDS=1; [ -f q3.env ] && . ./q3.env
xenstore-write /local/pool/0/name Pool-0 /tool/xenconsoled/domid 1 \
  /local/domain/0/name Domain-0 /local/domain/0/domid 0 \
  /local/domain/1/name DomD /local/domain/1/domid 1
XENCONSOLED_TRACE=guest /usr/sbin/xenconsoled --pid-file=/run/xenconsoled.pid \
  --log=guest --log-dir=/var/log/xen/console
python3 xs-sock-relay.py > relay.log 2>&1 &
for i in $(seq 1 50); do [ -S /var/run/xenstored/socket ] && break; sleep 0.1; done
for v in vcan0 vcan9; do ip link add dev $v type vcan && ip link set $v up; done
sed '/^virtio = \[\]/d' domz.cfg > domz-can.cfg
cat >> domz-can.cfg <<'CFG'
virtio = [ "backend=1, type=virtio,device24, transport=mmio, grant_usage=0",
           "backend=1, type=virtio,device4, transport=mmio, grant_usage=0" ]
CFG
echo "=== domz-can.cfg (non-comment lines)"; grep -v '^#' domz-can.cfg | grep -v '^$'
for boot in $(seq 1 $N); do
  BUS=vcan0; [ $boot = $N ] && BUS=vcan9
  echo "=== BOOT $boot (CAN backend on $BUS, tester on vcan0)"
  rm -f /tmp/can.sock0 /tmp/rng.sock0
  RUST_LOG=debug ./vhost-device-can --socket-path /tmp/can.sock --can-devices $BUS > vdc-$boot.log 2>&1 &
  VDC=$!
  ./vhost-device-rng --socket-path /tmp/rng.sock > vdr-$boot.log 2>&1 &
  VDR=$!
  for i in $(seq 1 50); do [ -S /tmp/can.sock0 ] && [ -S /tmp/rng.sock0 ] && break; sleep 0.1; done
  ./xen-vhost-frontend --socket-path /tmp/ --foreign-mapping > xvf-$boot.log 2>&1 &
  XVF=$!
  sleep 1
  xl create -p domz-can.cfg 2>&1 | grep -v "^Parsing config"
  ID=$(xl domid DomZ); echo "DomZ domid=$ID"
  xenstore-ls -f /local/domain/1/backend/virtio/$ID | grep -E "/(base|irq|type|grant_usage) "
  sleep 2; xl unpause DomZ
  LOG=/var/log/xen/console/guest-DomZ.log
  for i in $(seq 1 60); do grep -q "diag task started\|refusing" $LOG 2>/dev/null && break; sleep 1; done
  sleep 2
  python3 canpy.py dump vcan0 80 200 "WIRE" > wire-$boot.log 2>&1 &
  W=$!
  sleep 0.5
  for round in $(seq 1 $ROUNDS); do echo "ROUND $round"; timeout 40 python3 isotp_probe.py vcan0; done
  sleep 1; kill $W 2>/dev/null; wait $W 2>/dev/null
  xl list | grep -E "Name|DomZ"
  echo "--- wire (vcan0)"; cat wire-$boot.log
  echo "--- DomZ console"; sed 's/\x1b\[[0-9;]*m//g' $LOG | grep -v '^$'
  echo "--- xen-vhost-frontend"; cat xvf-$boot.log
  for P in $VDC $XVF; do for T in /proc/$P/task/*; do
    echo "THREAD $(cat $T/comm) tid=$(basename $T) state=$(awk '{print $3}' $T/stat) wchan=$(cat $T/wchan) utime=$(awk '{print $14}' $T/stat)"
  done; done
  echo "--- vhost-device-can (non-frame lines)"; grep -v -E "New Can frame|canframe|^\[|0x" vdc-$boot.log | tail -20; grep -c "New Can frame" vdc-$boot.log
  xl destroy DomZ 2>/dev/null
  kill $XVF $VDC $VDR 2>/dev/null; wait $XVF $VDC $VDR 2>/dev/null
  rm -f $LOG
  echo "=== END BOOT $boot"
done
