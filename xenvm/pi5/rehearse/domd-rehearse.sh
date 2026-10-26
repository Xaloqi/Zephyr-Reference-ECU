#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
#
# DomD script for xenvm/pi5/rehearse.sh: the Pi 5 bench driver (xaloqi-can-bench,
# the file that ships in the SD image) run end to end under QEMU, before the
# board exists. What differs from the Pi, on purpose and only here:
#   - can0/can1 are vcan, joined into one bus by can_bridge.py (the HAT's two
#     channels on one wire); no bitrate (XAQ_VIRTUAL=1)
#   - the NUCLEO is fake_nucleo.py on can0 (not EDS)
#   - upstream xl, so no backend_type key (XAQ_BACKEND_TYPE=)
#   - the toolstack names and xenconsoled that SoDeV's domd-toolstack-prep sets up
#     are set up here, as domd-test-can.sh does
cd /root
LIB=/usr/libexec/xaloqi-can
mkdir -p $LIB /usr/lib/xen/boot /etc/xen
cp isotp_probe.py can_dump.py xs-sock-relay.py uds_timing.py $LIB/
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
# XAQ_P2_MAX_MS: TCG timing is not the Pi's; p2 is judged on timeouts and bad
# answers here, not on the 25 ms limit.
export XAQ_VIRTUAL=1 XAQ_BACKEND_TYPE= XAQ_LOGDIR=/root/log XAQ_P2_MAX_MS=1000
# This rootfs has no /bin/sh (busybox installs sh in /usr/local/bin), so the
# script's #!/bin/sh cannot run directly; busybox ash is the stricter POSIX shell.
step() { echo "=== STEP xaloqi-can-bench $*"; busybox sh /usr/local/bin/xaloqi-can-bench "$@" 2>&1
         echo "=== END STEP xaloqi-can-bench $1"; }
B=step
$B up
python3 can_bridge.py can0 can1 > bridge.log 2>&1 &
python3 fake_nucleo.py can0 > nucleo.log 2>&1 &
# Python starts slowly under TCG: wait until both are bound, or the first
# request is lost (seen in the first rehearsal).
for i in $(seq 1 100); do grep -q bridge bridge.log && grep -q 'fake NUCLEO' nucleo.log && break; sleep 0.1; done
$B nucleo
$B domz can0
$B p2 0 200
$B p2 1 200
$B canary
$B down
echo "=== REHEARSAL DONE"
