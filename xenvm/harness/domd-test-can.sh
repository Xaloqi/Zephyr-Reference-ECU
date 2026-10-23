#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Runs in DomD for `xenvm/run.sh can`: EDS (ReferenceBCM, CAN) in DomZ on
# virtio-can, served from DomD by rust-vmm vhost-device-can (on vcan0) and
# vhost-device-rng, through Linaro's xen-vhost-frontend (grant_usage = 0).
# Boots 1..N: UDS over ISO-TP from DomD (kernel CAN_ISOTP), every frame on the
# wire printed. Boot N+1 is the canary: the CAN backend sits on vcan9 while the
# tester stays on vcan0, so nothing may answer. ../scripts/check_can.py judges.
# N comes from /root/can.env (BOOTS, default 2).
cd /root
BOOTS=2; [ -f can.env ] && . ./can.env
LAST=$((BOOTS + 1))

echo "=== xl info (DomD is the toolstack)"
xl info | grep -E "^(xen_version|xen_caps|nr_cpus|free_memory)"

# As in domd-test.sh: the names and the console backend that SoDeV's
# domd-toolstack-prep writes.
xenstore-write /local/pool/0/name Pool-0 /tool/xenconsoled/domid 1 \
  /local/domain/0/name Domain-0 /local/domain/0/domid 0 \
  /local/domain/1/name DomD /local/domain/1/domid 1
XENCONSOLED_TRACE=guest /usr/sbin/xenconsoled --pid-file=/run/xenconsoled.pid \
  --log=guest --log-dir=/var/log/xen/console

# xen-vhost-frontend talks to xenstore only through xenstored's Unix socket,
# which exists only where xenstored runs (Dom0). In a driver domain the same
# protocol is on /dev/xen/xenbus; xs-sock-relay.py serves one from the other.
python3 xs-sock-relay.py > relay.log 2>&1 &
for i in $(seq 1 50); do [ -S /var/run/xenstored/socket ] && break; sleep 0.1; done
for v in vcan0 vcan9; do ip link add dev $v type vcan && ip link set $v up; done

sed '/^virtio = \[\]/d' domz.cfg > domz-can.cfg
cat >> domz-can.cfg <<'CFG'
virtio = [ "backend=1, type=virtio,device24, transport=mmio, grant_usage=0",
           "backend=1, type=virtio,device4, transport=mmio, grant_usage=0" ]
CFG
echo "=== domz-can.cfg (non-comment lines)"; grep -v '^#' domz-can.cfg | grep -v '^$'

for boot in $(seq 1 $LAST); do
  BUS=vcan0; [ $boot = $LAST ] && BUS=vcan9
  echo "=== BOOT $boot (CAN backend on $BUS, tester on vcan0)"
  rm -f /tmp/can.sock0 /tmp/rng.sock0
  ./vhost-device-can --socket-path /tmp/can.sock --can-devices $BUS > vdc-$boot.log 2>&1 &
  VDC=$!
  ./vhost-device-rng --socket-path /tmp/rng.sock > vdr-$boot.log 2>&1 &
  VDR=$!
  for i in $(seq 1 50); do [ -S /tmp/can.sock0 ] && [ -S /tmp/rng.sock0 ] && break; sleep 0.1; done
  ./xen-vhost-frontend --socket-path /tmp/ --foreign-mapping > xvf-$boot.log 2>&1 &
  XVF=$!
  sleep 1
  # Paused first, as in domd-test.sh: the frontend must claim the virtio slots
  # before the guest probes them.
  xl create -p domz-can.cfg 2>&1 | grep -v "^Parsing config"
  ID=$(xl domid DomZ 2>/dev/null)
  echo "DomZ domid=$ID"
  if [ -n "$ID" ]; then
    echo "--- xenstore: virtio backend nodes live under DomD (/local/domain/1)"
    xenstore-ls -f /local/domain/1/backend/virtio/$ID | grep -E "/(base|irq|type|transport|grant_usage) "
    sleep 2; xl unpause DomZ
    LOG=/var/log/xen/console/guest-DomZ.log
    for i in $(seq 1 60); do grep -q "diag task started\|refusing" $LOG 2>/dev/null && break; sleep 1; done
    sleep 2
    python3 can_dump.py vcan0 60 200 WIRE > wire-$boot.log 2>&1 &
    W=$!
    sleep 0.5
    echo "--- ISO-TP tester (DomD vcan0, 0x7E0 -> EDS in DomZ, 0x7E8 back)"
    timeout 40 python3 isotp_probe.py vcan0
    sleep 1; kill $W 2>/dev/null; wait $W 2>/dev/null
    xl list | grep -E "^(Name|DomZ) "
    echo "--- wire (vcan0)"; cat wire-$boot.log
    echo "--- DomZ console (Zephyr + EDS, via xenconsoled in DomD)"
    sed 's/\x1b\[[0-9;]*m//g' $LOG | grep -v '^$'
    rm -f $LOG
  fi
  echo "--- xen-vhost-frontend log"; cat xvf-$boot.log
  echo "--- backend threads"
  for P in $VDC $VDR $XVF; do for T in /proc/$P/task/*; do
    echo "THREAD $(cat $T/comm) state=$(sed 's/.*) \(.\).*/\1/' $T/stat) wchan=$(cat $T/wchan)"
  done; done 2>/dev/null
  xl destroy DomZ 2>/dev/null
  kill $XVF $VDC $VDR 2>/dev/null; wait $XVF $VDC $VDR 2>/dev/null
  echo "=== END BOOT $boot"
done
