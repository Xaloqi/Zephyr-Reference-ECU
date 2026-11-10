#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
#
# DomD script for the DomD-load rehearsal (cells C/D of the Pi 5 bench): the load
# script arrives the way it does on the bench (base64 + sha256, decoded and checked
# in DomD), then P2 for the stand-in NUCLEO (C) and DomZ-CAN (D) with DomD idle and
# loaded. Setup as in domd-rehearse.sh. Two things are stand-ins here only: the
# NUCLEO is fake_nucleo.py, and candump (no can-utils in this rootfs) is can_dump.py.
# TCG timing says nothing about the Pi; what this shows is that the load starts, saturates
# every vCPU, leaves the tester able to measure, and stops completely.
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
for v in can0 can1; do ip link add dev $v type vcan; done
export XAQ_VIRTUAL=1 XAQ_BACKEND_TYPE= XAQ_LOGDIR=/root/log XAQ_P2_MAX_MS=1000 XAQ_CAN_FD=0
B() { busybox sh /usr/local/bin/xaloqi-can-bench "$@" 2>&1; }
L() { busybox sh /usr/local/bin/xaloqi-domd-load "$@" 2>&1; }

echo "=== DELIVERY: base64 + sha256, as sent over the console"
base64 -d xaloqi-domd-load.b64 > /usr/local/bin/xaloqi-domd-load
sha256sum -c xaloqi-domd-load.sha && chmod 755 /usr/local/bin/xaloqi-domd-load && echo SEND-OK
cat > /usr/local/bin/candump <<'STUB'
#!/usr/bin/python3
import os, sys
os.execv("/usr/bin/python3", ["python3", "/usr/libexec/xaloqi-can/can_dump.py", "can1", "100000", "1000000000", "X"])
STUB
chmod 755 /usr/local/bin/candump
echo "DomD vCPUs: $(grep -c '^processor' /proc/cpuinfo)"

B up
python3 can_bridge.py can0 can1 > bridge.log 2>&1 &
python3 fake_nucleo.py can0 > nucleo.log 2>&1 &
for i in $(seq 1 100); do grep -q bridge bridge.log && grep -q 'fake NUCLEO' nucleo.log && break; sleep 0.1; done
B domz can0 | grep -E "^(DomZ-CAN domid|PASS|FAIL)"

echo "=== IDLE"
L check
B p2 0 200 | grep -E "^(P2 |PASS|FAIL)"
B p2 1 200 | grep -E "^(P2 |PASS|FAIL)"
echo "=== LOADED by hand"
L start 300
L status
L check
echo "--- start again must refuse"
L start 300
echo "--- P2 under load, ECU 0 (cell C, stand-in) and ECU 1 (cell D)"
B p2 0 200 | grep -E "^(P2 |PASS|FAIL)"
B p2 1 200 | grep -E "^(P2 |PASS|FAIL)"
L check
echo "=== STOP"
L stop
L status
echo "--- stopped: check must now FAIL"
L check
B p2 1 200 | grep -E "^(P2 |PASS|FAIL)"
echo "=== cell: one run of C and D on pCPU 0, then on pCPU 3"
L cell 0 200
L cell 3 200
L status
echo "=== watchdog: start 6, wait 9 s"
L start 6
sleep 9
L status
B down
echo "=== REHEARSAL DONE"
