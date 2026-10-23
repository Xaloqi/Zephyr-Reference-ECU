#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Q1 option (a): vhost-device-can attached through QEMU's generic vhost-user device
# (vhost-user-test-device, virtio-id 36) on the xenpvh device model in DomD.
cd /root
xenstore-write /local/pool/0/name Pool-0 /tool/xenconsoled/domid 1 \
  /local/domain/0/name Domain-0 /local/domain/0/domid 0 \
  /local/domain/1/name DomD /local/domain/1/domid 1
XENCONSOLED_TRACE=guest /usr/sbin/xenconsoled --pid-file=/run/xenconsoled.pid \
  --log=guest --log-dir=/var/log/xen/console
ip link add dev vcan0 type vcan && ip link set vcan0 up
RUST_LOG=debug ./vhost-device-can --socket-path /tmp/can.sock --can-devices vcan0 > vdc.log 2>&1 &
for i in $(seq 1 50); do [ -S /tmp/can.sock0 ] && break; sleep 0.1; done
xl create -p linux-guest.cfg 2>&1 | grep -v "^Parsing config"
ID=$(xl domid LinuxCanGuest); echo "guest domid=$ID"
echo "--- attempt 1: guest RAM as xenpvh provides it"
timeout 20 ./qemu-dm-vu -xen-domid $ID -xen-attach -name LinuxCanGuest -display none -nographic -nodefaults \
  -no-user-config -monitor none -serial none -machine xenpvh -m 384 \
  -global virtio-mmio.force-legacy=false \
  -chardev socket,id=vc0,path=/tmp/can.sock0 \
  -device vhost-user-test-device,chardev=vc0,virtio-id=36,num_vqs=3 > qa1.log 2>&1 &
QP=$!; sleep 4; xl unpause LinuxCanGuest; sleep 12
echo "qemu alive: $(cat /proc/$QP/comm 2>/dev/null || echo NO)"; cat qa1.log
kill $QP 2>/dev/null; wait $QP 2>/dev/null
xl destroy LinuxCanGuest 2>/dev/null
echo "--- attempt 2: shared memfd backend (what vhost-user needs)"
xl create -p linux-guest.cfg 2>&1 | grep -v "^Parsing config"
ID=$(xl domid LinuxCanGuest)
timeout 20 ./qemu-dm-vu -xen-domid $ID -xen-attach -name LinuxCanGuest -display none -nographic -nodefaults \
  -no-user-config -monitor none -serial none -machine xenpvh,memory-backend=m0 -m 384 \
  -object memory-backend-memfd,id=m0,size=384M,share=on \
  -global virtio-mmio.force-legacy=false \
  -chardev socket,id=vc0,path=/tmp/can.sock0 \
  -device vhost-user-test-device,chardev=vc0,virtio-id=36,num_vqs=3 > qa2.log 2>&1 &
QP=$!; sleep 4; xl unpause LinuxCanGuest; sleep 12
echo "qemu alive: $(cat /proc/$QP/comm 2>/dev/null || echo NO)"; cat qa2.log
echo "--- Linux guest console"; sed 's/\x1b\[[0-9;]*m//g' /var/log/xen/console/guest-LinuxCanGuest.log | grep -i -E "virtio|can0|LGUEST|Unable|abort" | head -20
kill $QP 2>/dev/null; xl destroy LinuxCanGuest 2>/dev/null
echo "--- vhost-device-can"; tail -10 vdc.log
