#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
#
# DomD script for the B4 rehearsal (the Pi 5 bench, session 4) under QEMU, in the harness of
# rehearse.sh / rehearse-b3.sh: every cell B4 runs, with the tools as they are baked into the
# image, and the stop rule of the pin check tried on purpose. Setup as in domd-load-rehearse.sh,
# with two differences that matter: domain 1 is named Dom0less-1 as on the Pi (B3 hid a naming
# bug behind a rehearsal that renamed it), and the tools are used by their installed names.
# Stand-ins only here: the NUCLEO is fake_nucleo.py, and candump (no can-utils in this rootfs)
# is can_dump.py. TCG timing says nothing about the Pi; what this shows is that every cell runs
# end to end, the guest's pCPU is printed in each run, and a wrong pin stops the cell.
#   XENVM_CAN_BOOTS   0: everything; 1: only the group runner (`rehearse-b3.sh <build> b4 group`);
#   B4_IDLE_SECS (default 20) is the busy-poll window of cell 5
cd /root
LIB=/usr/libexec/xaloqi-can
mkdir -p $LIB /usr/lib/xen/boot /etc/xen
cp isotp_probe.py can_dump.py xs-sock-relay.py uds_timing.py isotp_burst.py $LIB/
cp vhost-device-can vhost-device-rng xen-vhost-frontend /usr/local/bin/
cp xaloqi-can-bench xaloqi-domd-load xaloqi-b3-group xaloqi-proc-cpu xaloqi-teardown-loop /usr/local/bin/
chmod 755 /usr/local/bin/xaloqi-*
cp zephyr-domz.bin /usr/lib/xen/boot/zephyr-domz-can.bin
cp domz.cfg /etc/xen/domz.cfg
xenstore-write /local/pool/0/name Pool-0 /tool/xenconsoled/domid 1 \
  /local/domain/0/name Domain-0 /local/domain/0/domid 0 \
  /local/domain/1/name Dom0less-1 /local/domain/1/domid 1
XENCONSOLED_TRACE=guest /usr/sbin/xenconsoled --pid-file=/run/xenconsoled.pid \
  --log=guest --log-dir=/var/log/xen/console
FD=; BOOTS=0; [ -f can.env ] && . ./can.env
for v in can0 can1; do ip link add dev $v type vcan; done
export XAQ_VIRTUAL=1 XAQ_BACKEND_TYPE= XAQ_LOGDIR=/root/log XAQ_P2_MAX_MS=1000
export XAQ_CAN_FD=${FD:-0}
# This rootfs has no /bin/sh: run the scripts through busybox ash, as on the other rehearsals.
B() { busybox sh /usr/local/bin/xaloqi-can-bench "$@" 2>&1; }
L() { busybox sh /usr/local/bin/xaloqi-domd-load "$@" 2>&1; }
Bp() { pin=$1; shift; env XAQ_DOMZ_CPUS=$pin busybox sh /usr/local/bin/xaloqi-can-bench "$@" 2>&1; }
cat > /usr/local/bin/candump <<'STUB'
#!/usr/bin/python3
import os, sys
os.execv("/usr/bin/python3", ["python3", "/usr/libexec/xaloqi-can/can_dump.py", "can1", "100000", "1000000000", "X"])
STUB
chmod 755 /usr/local/bin/candump
echo "=== IMAGE: sha256 of the tools as installed"
sha256sum /usr/local/bin/xaloqi-can-bench /usr/local/bin/xaloqi-domd-load /usr/local/bin/xaloqi-b3-group /usr/local/bin/xaloqi-proc-cpu /usr/local/bin/xaloqi-teardown-loop | cut -c1-16,65-
echo "domain 1 is named: $(xenstore-read /local/domain/1/name); DomD vCPUs: $(grep -c '^processor' /proc/cpuinfo); FD=${XAQ_CAN_FD}"

B up
python3 can_bridge.py can0 can1 > bridge.log 2>&1 &
python3 fake_nucleo.py can0 $([ "$XAQ_CAN_FD" = 1 ] && echo fd) > nucleo.log 2>&1 &
for i in $(seq 1 100); do grep -q bridge bridge.log && grep -q 'fake NUCLEO' nucleo.log && break; sleep 0.1; done
P2='^(P2 |PASS|FAIL)'

if [ "$BOOTS" != 1 ]; then
echo "=== CELL 1 (A): NUCLEO reference, DomD idle"
B nucleo | grep -E '^(PASS|FAIL)'
B p2 0 200 | grep -E "$P2"

echo "=== CELL 2 (B'): DomZ-CAN idle on pCPU 3"
Bp 3 domz can0 | grep -E '^(DomZ-CAN domid|PASS|FAIL)'
B p2 1 200 | grep -E "$P2"
echo "=== CELL 2b (B): DomZ-CAN idle on pCPU 0"
Bp 0 domz can0 | grep -E '^(DomZ-CAN domid|PASS|FAIL)'
B p2 1 200 | grep -E "$P2"

echo "=== CELL 3 (D): DomD loaded, DomZ-CAN on pCPU 3"
L cell 3 200
echo "=== CELL 4 (D): DomD loaded, DomZ-CAN on pCPU 0"
L cell 0 200

echo "=== STOP RULE: a bench tool that ignores XAQ_DOMZ_CPUS (as the 11-07 classic image's did)"
mkdir -p /tmp/stale
sed 's/XAQ_DOMZ_CPUS/XAQ_DOMZ_CPUS_IGNORED/g' /usr/local/bin/xaloqi-can-bench > /tmp/stale/xaloqi-can-bench
grep -c XAQ_DOMZ_CPUS /tmp/stale/xaloqi-can-bench | sed 's/^/XAQ_DOMZ_CPUS mentions left in the stale copy: /'
env PATH=/tmp/stale:$PATH busybox sh /usr/local/bin/xaloqi-domd-load cell 3 200 2>&1; echo "cell rc (must be 1): $?"
L status
echo "=== STOP RULE again, the right tool: cell must pass"
L cell 3 100 | grep -E '^(===|DomZ-CAN vCPU|FAIL|PASS)'

echo "=== CELL 5: busy-poll, vhost-device-can CPU with DomZ-CAN up and the bus idle"
Bp 3 domz can0 | grep -E '^(PASS|FAIL)'
busybox sh /usr/local/bin/xaloqi-proc-cpu vhost-device-can ${B4_IDLE_SECS:-20} 5

fi   # BOOTS != 1
echo "=== GROUP RUNNER: xaloqi-b3-group 3 2 100 (two runs of 100 samples, on a pin that holds)"
# the stand-ins are already up: no second `up`
XAQ_GROUP_UP=0 busybox sh /usr/local/bin/xaloqi-b3-group 3 2 100 2>&1 | grep -E '^(==|#####|===|DomZ-CAN vCPU|P2 |PASS|FAIL|GROUP)'

echo "=== IDLE GROUP (cell 2 on the Pi): DomD idle, DomZ-CAN on pCPU 3, no NUCLEO cell"
XAQ_GROUP_UP=0 XAQ_LOAD_NONE=1 XAQ_LOAD_SKIP_C=1 busybox sh /usr/local/bin/xaloqi-b3-group 3 2 100 2>&1 | grep -E '^(#####|===|DomZ-CAN vCPU|---|P2 |PASS|FAIL|GROUP|soc)'
L status

echo "=== CELL 7: create/destroy loop, 3 cycles (10 on the Pi)"
XAQ_DOMZ_CPUS=3 busybox sh /usr/local/bin/xaloqi-teardown-loop 3 2>&1 | grep -aE '^(==|RESULT|SUMMARY|FAIL|frontend logs)'
ls /root/teardown | tr '\n' ' '; echo

echo "=== DIAG"
echo "--- xl vcpu-list"; xl vcpu-list
B down
echo "=== REHEARSAL DONE"
