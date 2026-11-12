#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
#
# DomD script for the busy-poll comparison (xenvm/pi5/rehearse-b3.sh <build> idle [SECS]): the CPU time
# of vhost-device-can with the bus idle, for the binary before the reader-poll patch (vhost-device-can-before)
# and the one built now (vhost-device-can), as rust-vmm/vhost-device#1020 measured it (79 s of CPU in 80 s
# before). The same tool the bench uses, xaloqi-proc-cpu, takes the reading. Setup as in domd-teardown.sh.
#   XENVM_CAN_BOOTS   the window in seconds (default 80; boot.sh passes it as BOOTS in can.env)
cd /root
cp vhost-device-can vhost-device-can-before xaloqi-proc-cpu /usr/local/bin/
chmod 755 /usr/local/bin/*
BOOTS=80; [ -f can.env ] && . ./can.env; SECS=$BOOTS
ip link add dev can0 type vcan; ip link set can0 up
for which in before after; do
  bin=/usr/local/bin/vhost-device-can; [ $which = before ] && bin=/usr/local/bin/vhost-device-can-before
  echo "=== $which: $(sha256sum $bin | cut -c1-16) idle bus, ${SECS} s"
  rm -f /run/idle.sock*
  $bin --socket-path /run/idle.sock --can-devices can0 > /run/idle-$which.log 2>&1 &
  P=$!
  sleep 2
  # xaloqi-proc-cpu matches argv[0]'s basename: vhost-device-can-before for the old one
  busybox sh /usr/local/bin/xaloqi-proc-cpu $(basename $bin) $SECS 5
  kill $P; wait $P 2>/dev/null
done
echo "=== REHEARSAL DONE"
