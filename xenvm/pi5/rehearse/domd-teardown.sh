#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
#
# DomD script for the teardown reproduction under QEMU (xenvm/pi5/rehearse.sh with
# XENVM_CAN_DOMD_TEST pointing here): create and destroy DomZ-CAN in a loop, the way
# the Pi bench does (xaloqi-can-bench domz, then down), and after each destroy record
# what xen-vhost-frontend printed and what Xen says about the domain. Setup as in
# domd-rehearse.sh; there is no NUCLEO stand-in, DomZ-CAN is the only ECU.
#   XENVM_CAN_BOOTS      create/destroy cycles (default 4; boot.sh passes it as BOOTS in can.env)
cd /root
LIB=/usr/libexec/xaloqi-can
mkdir -p $LIB /usr/lib/xen/boot /etc/xen
cp isotp_probe.py can_dump.py xs-sock-relay.py uds_timing.py isotp_burst.py $LIB/
cp vhost-device-can vhost-device-rng xen-vhost-frontend xaloqi-can-bench /usr/local/bin/
chmod 755 /usr/local/bin/xaloqi-can-bench
cp zephyr-domz.bin /usr/lib/xen/boot/zephyr-domz-can.bin
cp domz.cfg /etc/xen/domz.cfg

xenstore-write /local/pool/0/name Pool-0 /tool/xenconsoled/domid 1 \
  /local/domain/0/name Domain-0 /local/domain/0/domid 0 \
  /local/domain/1/name DomD /local/domain/1/domid 1
XENCONSOLED_TRACE=guest /usr/sbin/xenconsoled --pid-file=/run/xenconsoled.pid \
  --log=guest --log-dir=/var/log/xen/console

BOOTS=4; [ -f can.env ] && . ./can.env; CYCLES=$BOOTS   # XENVM_CAN_BOOTS
for v in can0 can1; do ip link add dev $v type vcan; done
export XAQ_VIRTUAL=1 XAQ_BACKEND_TYPE= XAQ_LOGDIR=/root/log XAQ_P2_MAX_MS=1000 XAQ_CAN_FD=0
B() { busybox sh /usr/local/bin/xaloqi-can-bench "$@" 2>&1; }
B up
python3 can_bridge.py can0 can1 > bridge.log 2>&1 &
for i in $(seq 1 100); do grep -q bridge bridge.log && break; sleep 0.1; done

state() { # what Xen and the frontend look like now
  echo "--- xl list"; xl list
  xl dmesg -c > /dev/null
  xl debug-keys q; sleep 1
  echo "--- xen 'q' (domain info), dying domains and their refcounts"
  xl dmesg | sed 's/\x1b\[[0-9;]*m//g' | grep -E "General information for domain|refcnt=|dying=|paused=|nr_pages|handle=" | tail -n 40
  P=$(cat /run/xaloqi-can/xvf.pid 2>/dev/null)
  if [ -n "$P" ] && [ -d /proc/$P ]; then
    echo "--- xen-vhost-frontend pid $P: $(ls /proc/$P/task | wc -l) threads, $(grep -c privcmd /proc/$P/maps) privcmd mappings, $(ls /proc/$P/fd | wc -l) fds"
    for T in /proc/$P/task/*; do echo "  THREAD $(cat $T/comm) wchan=$(cat $T/wchan)"; done
  else
    echo "--- xen-vhost-frontend: not running"
  fi
  echo "--- xenstore backend/virtio"; xenstore-ls -f /local/domain/1/backend/virtio 2>&1 | head -12
  echo "--- xl create processes: $(ps | grep -c '[x]l create')"
}

for n in $(seq 1 ${CYCLES:-2}); do
  echo "=== CYCLE $n create"
  B domz can0 | grep -E "^(DomZ-CAN domid|PASS|FAIL)|slot"
  echo "--- xen-vhost-frontend log before destroy"; cat /run/xaloqi-can/xvf.log
  echo "=== CYCLE $n destroy"
  xl destroy DomZ-CAN; echo "xl destroy rc=$?"
  sleep 3
  echo "--- xen-vhost-frontend log after destroy"; cat /run/xaloqi-can/xvf.log
  state
  echo "=== END CYCLE $n"
done
# Cases below. Each starts from fresh backends (as the bench's `backends` does), so a
# panicked frontend (its mutex is poisoned for good) cannot colour the next case.
R=/run/xaloqi-can
CFG=$R/domz-can.cfg
stop_all() {
  for p in xvf vdc vdr; do [ -f $R/$p.pid ] && kill "$(cat $R/$p.pid)" 2>/dev/null; rm -f $R/$p.pid; done
  sleep 1
}
start_all() {
  rm -f $R/can.sock0 $R/rng.sock0
  vhost-device-can --socket-path $R/can.sock --can-devices can0 > $R/vdc.log 2>&1 & echo $! > $R/vdc.pid
  vhost-device-rng --socket-path $R/rng.sock > $R/vdr.log 2>&1 & echo $! > $R/vdr.pid
  for i in $(seq 1 50); do [ -S $R/can.sock0 ] && [ -S $R/rng.sock0 ] && break; sleep 0.1; done
  RUST_BACKTRACE=1 xen-vhost-frontend --socket-path $R/ --foreign-mapping > $R/xvf.log 2>&1 & echo $! > $R/xvf.pid
  sleep 1
}
xlt() { # xl with a timeout and its duration; a timeout dumps the process list
  t0=$(date +%s)
  timeout 60 xl "$@" > /root/xlt.out 2>&1; rc=$?
  grep -v "^Parsing config\|^libxl" /root/xlt.out
  echo "(xl $1 took $(( $(date +%s) - t0 )) s, rc=$rc)"
  if [ $rc -ge 124 ]; then echo "TIMEOUT: xl $* (60 s)"; ps; fi
  return 0
}
wait_dev() { # <domid>: the frontend has created both devices
  for i in $(seq 1 100); do grep -q "Created device $1 / 1" $R/xvf.log && break; sleep 0.1; done
}

# Where the guest is when DomZ-CAN is destroyed. Every case starts from fresh backends.
case_end() { # the state after a destroy, then what a restart of the frontend does
  echo "--- xen-vhost-frontend log"; cat $R/xvf.log
  state
  echo "--- restart the backends (kill xen-vhost-frontend, start a new one)"
  stop_all; start_all
  echo "--- new xen-vhost-frontend log"; cat $R/xvf.log
  state
  stop_all
}
if [ "$CYCLES" != 0 ]; then   # XENVM_CAN_BOOTS=0 runs the stale case alone
# PAUSED: devices created, guest never unpaused (what `xl create -p` then `xl destroy` does,
# e.g. the bench's create() on a failed check, or xl create failing after the domain exists).
echo "=== CASE paused: create -p, devices created, 3 s, destroy without unpause"
stop_all; xlt destroy DomZ-CAN; start_all
xlt create -p $CFG
ID=$(xl domid DomZ-CAN); wait_dev $ID
sleep 3
xlt destroy DomZ-CAN
sleep 3
case_end
# STARTED: guest unpaused and destroyed 0.3 s later, before it has configured a virtio device.
echo "=== CASE started: create -p, unpause, destroy 0.3 s later"
stop_all; xlt destroy DomZ-CAN; start_all
xlt create -p $CFG
ID=$(xl domid DomZ-CAN); wait_dev $ID
xl unpause DomZ-CAN; sleep 0.3
xlt destroy DomZ-CAN
sleep 3
case_end
fi
# ACTIVE: the guest booted and answered (cycles above), then destroyed: clean (control).
# STALE-EVENT: a node of a domain that no longer exists is written while a frontend runs.
echo "=== CASE stale: backend nodes of a dead domain appear while a frontend runs"
stop_all; xlt destroy DomZ-CAN; start_all
sed -n 's/^\(\/local\/domain\/1\/backend\/virtio\/99\/[^ ]*\) = "\(.*\)"$/\1 \2/p' <<'NODES' > $R/nodes.txt
/local/domain/1/backend/virtio/99/0/frontend = "/local/domain/99/device/virtio/0"
/local/domain/1/backend/virtio/99/0/frontend-id = "99"
/local/domain/1/backend/virtio/99/0/online = "1"
/local/domain/1/backend/virtio/99/0/state = "2"
/local/domain/1/backend/virtio/99/0/irq = "33"
/local/domain/1/backend/virtio/99/0/base = "0x2000000"
/local/domain/1/backend/virtio/99/0/type = "virtio,device24"
/local/domain/1/backend/virtio/99/0/transport = "mmio"
/local/domain/1/backend/virtio/99/0/grant_usage = "0"
NODES
# libxl creates the device directory first; that is the event xen-vhost-frontend acts on
# (paths of exactly <guest>/<device>), so do the same.
xenstore-write /local/domain/1/backend/virtio/99/0 ""
while read k v; do xenstore-write "$k" "$v"; done < $R/nodes.txt
sleep 3
echo "--- new xen-vhost-frontend log"; cat $R/xvf.log
state
stop_all
xenstore-rm /local/domain/1/backend/virtio 2>/dev/null

echo "=== final"
state
echo "=== REHEARSAL DONE"
