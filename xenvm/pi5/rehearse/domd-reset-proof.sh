#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
#
# DomD script for the reset() proof (xenvm/pi5/rehearse-b3.sh <build> reset [N]): N times, from fresh
# backends, create DomZ-CAN paused (`xl create -p`, devices created, never unpaused) and destroy it,
# and count per case what xen-vhost-frontend panicked on and whether a dying domain is left. Run on
# the build before the fix (vireshk-vhost-abf24853-reset.patch and xen-vhost-frontend-a1e333c5-teardown
# .patch) and on the one after it, with this same script. Setup as in domd-teardown.sh.
#   XENVM_CAN_BOOTS   N, the number of paused cases (default 6; boot.sh passes it as BOOTS in can.env)
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
  /local/domain/1/name Dom0less-1 /local/domain/1/domid 1
XENCONSOLED_TRACE=guest /usr/sbin/xenconsoled --pid-file=/run/xenconsoled.pid \
  --log=guest --log-dir=/var/log/xen/console
BOOTS=6; [ -f can.env ] && . ./can.env; N=$BOOTS
for v in can0 can1; do ip link add dev $v type vcan; done
export XAQ_VIRTUAL=1 XAQ_BACKEND_TYPE= XAQ_LOGDIR=/root/log XAQ_P2_MAX_MS=1000 XAQ_CAN_FD=0
B() { busybox sh /usr/local/bin/xaloqi-can-bench "$@" 2>&1; }
B up | tail -n 1
R=/run/xaloqi-can; mkdir -p $R
# The bench tool writes the DomZ-CAN config; take it from one `domz` run, then the cases use it.
B domz can0 | grep -E '^(PASS|FAIL)'
xl destroy DomZ-CAN; sleep 2
CFG=$R/domz-can.cfg
stop_all() { for p in xvf vdc vdr; do [ -f $R/$p.pid ] && kill "$(cat $R/$p.pid)" 2>/dev/null; rm -f $R/$p.pid; done; sleep 1; }
start_all() {
  rm -f $R/can.sock0 $R/rng.sock0
  vhost-device-can --socket-path $R/can.sock --can-devices can0 > $R/vdc.log 2>&1 & echo $! > $R/vdc.pid
  vhost-device-rng --socket-path $R/rng.sock > $R/vdr.log 2>&1 & echo $! > $R/vdr.pid
  for i in $(seq 1 50); do [ -S $R/can.sock0 ] && [ -S $R/rng.sock0 ] && break; sleep 0.1; done
  RUST_BACKTRACE=1 xen-vhost-frontend --socket-path $R/ --foreign-mapping > $R/xvf.log 2>&1 & echo $! > $R/xvf.pid
  sleep 1
}
wait_dev() { for i in $(seq 1 100); do grep -q "Created device $1 / 1" $R/xvf.log && break; sleep 0.1; done; }
bad=0; dyingruns=0; poison=0
for n in $(seq 1 $N); do
  echo "=== CASE paused $n: create -p, devices created, 3 s, destroy without unpause"
  stop_all; xl destroy DomZ-CAN 2>/dev/null; start_all
  d0=$(xl list | grep -c '(null)')
  timeout 60 xl create -p $CFG > /root/xlc.out 2>&1
  ID=$(xl domid DomZ-CAN); wait_dev "$ID"
  sleep 3
  t0=$(date +%s); timeout 90 xl destroy DomZ-CAN > /root/xld.out 2>&1; rc=$?
  sleep 3
  panics=$(grep -c 'panicked' $R/xvf.log); rp=$(grep -c 'vhost-user-frontend.*reset\|generic.rs\|device.rs' $R/xvf.log)
  pz=$(grep -c PoisonError $R/xvf.log)
  dying=$(( $(xl list | grep -c '(null)') - d0 ))   # new dying domains from this case
  echo "RESULT paused $n: destroy rc=$rc in $(( $(date +%s) - t0 )) s, frontend panics=$panics, in reset()=$rp, PoisonError=$pz, new dying domains=$dying"
  grep -a 'panicked' -A1 $R/xvf.log | head -n 4
  [ "$panics" -gt 0 ] && bad=$((bad + 1))
  [ "$dying" -gt 0 ] && dyingruns=$((dyingruns + 1))
  [ "$pz" -gt 0 ] && poison=$((poison + 1))
  stop_all
  xl list | grep '(null)' | sed 's/^/  left: /'
done
echo "SUMMARY paused: $N cases, $bad with a frontend panic, $poison with PoisonError, $dyingruns with a dying domain left"
echo "=== REHEARSAL DONE"
