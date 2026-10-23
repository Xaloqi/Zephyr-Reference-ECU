#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Q2 in DomD: Zephyr DomZ (can_virtio test app) on virtio-can served by
# vhost-device-can + xen-vhost-frontend, vcan0 in DomD, grant_usage=0.
cd /root
xenstore-write /local/pool/0/name Pool-0 /tool/xenconsoled/domid 1 \
  /local/domain/0/name Domain-0 /local/domain/0/domid 0 \
  /local/domain/1/name DomD /local/domain/1/domid 1
XENCONSOLED_TRACE=guest /usr/sbin/xenconsoled --pid-file=/run/xenconsoled.pid \
  --log=guest --log-dir=/var/log/xen/console
ip link add dev vcan0 type vcan && ip link set vcan0 up
RUST_LOG=debug ./vhost-device-can --socket-path /tmp/can.sock --can-devices vcan0 > vdc.log 2>&1 &
for i in $(seq 1 50); do [ -S /tmp/can.sock0 ] && break; sleep 0.1; done
python3 xs-sock-relay.py > relay.log 2>&1 &
for i in $(seq 1 50); do [ -S /var/run/xenstored/socket ] && break; sleep 0.1; done
./xen-vhost-frontend --socket-path /tmp/ --foreign-mapping > xvf.log 2>&1 &
sleep 1
sed '/^virtio = \[\]/d' domz.cfg > domz-can.cfg
echo 'virtio = [ "backend=1, type=virtio,device24, transport=mmio, grant_usage=0" ]' >> domz-can.cfg
echo "=== domz-can.cfg"; grep -v '^#' domz-can.cfg | grep -v '^$'
python3 canpy.py dump vcan0 45 40 "DOMD RX" > domd-rx.log 2>&1 &
DUMP=$!
xl create -p domz-can.cfg 2>&1 | grep -v "^Parsing config"
ID=$(xl domid DomZ); echo "DomZ domid=$ID"
sleep 2; xl unpause DomZ
LOG=/var/log/xen/console/guest-DomZ.log
for i in $(seq 1 60); do grep -q "ZCAN READY" $LOG 2>/dev/null && break; sleep 1; done
echo "DomZ ready after ~${i}s"
python3 canpy.py send vcan0 321#DEADBEEF 18DAF110#0102030405 555#55 7E0#0211 | sed 's/^/DOMD /'
for i in $(seq 1 60); do grep -q "ZCAN RESULT" $LOG 2>/dev/null && break; sleep 1; done
sleep 1; kill $DUMP 2>/dev/null; wait $DUMP 2>/dev/null
for P in $(pidof vhost-device-can) $(pidof xen-vhost-frontend); do
  for T in /proc/$P/task/*; do
    echo "THREAD $(cat $T/comm) pid=$P tid=$(basename $T) state=$(awk '{print $3}' $T/stat) wchan=$(cat $T/wchan) syscall=$(cut -d' ' -f1-3 $T/syscall) utime=$(awk '{print $14}' $T/stat)"
  done
done
xl list
echo "--- DomZ console"; sed 's/\x1b\[[0-9;]*m//g' $LOG | grep -v '^$'
echo "--- DomD vcan0 capture"; cat domd-rx.log
echo "--- xen-vhost-frontend"; cat xvf.log
echo "--- vhost-device-can"; grep -v "New Can frame" vdc.log | tail -150
xl destroy DomZ 2>/dev/null
