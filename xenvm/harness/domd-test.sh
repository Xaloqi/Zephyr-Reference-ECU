#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Runs in DomD: create DomZ twice from SoDeV's domz.cfg + two virtio= entries
# (backend = DomD, grant_usage = 0), serve them with QEMU in DomD, and talk DoIP
# to EDS in DomZ. Every byte goes to the console; ../scripts/check.py judges.
cd /root

echo "=== xl info (DomD is the toolstack)"
xl info | grep -E "^(xen_version|xen_caps|nr_cpus|free_memory)"

# The SoDeV domd-toolstack-prep equivalent: the cpupool name xen-init-dom0 would
# write, the console backend pointed at DomD, and the names init-dom0less would
# write. xenconsoled runs here, as in SoDeV (/tool/xenconsoled/domid = 1).
xenstore-write /local/pool/0/name Pool-0 /tool/xenconsoled/domid 1 \
  /local/domain/0/name Domain-0 /local/domain/0/domid 0 \
  /local/domain/1/name DomD /local/domain/1/domid 1
XENCONSOLED_TRACE=guest /usr/sbin/xenconsoled --pid-file=/run/xenconsoled.pid \
  --log=guest --log-dir=/var/log/xen/console
xl list

sed '/^virtio = \[\]/d' domz.cfg > domz-p1.cfg
cat >> domz-p1.cfg <<'CFG'
virtio = [ "backend=1, type=virtio,device1, transport=mmio, grant_usage=0",
           "backend=1, type=virtio,device4, transport=mmio, grant_usage=0" ]
CFG
echo "=== domz-p1.cfg (non-comment lines)"; grep -v '^#' domz-p1.cfg | grep -v '^$'

ip tuntap add dev tapz mode tap
ip addr add 192.0.2.2/24 dev tapz
ip link set tapz up

for boot in 1 2; do
  echo "=== BOOT $boot"
  # Paused first: the guest probes its virtio slots at boot, and an MMIO access
  # nobody claims becomes an injected data abort.
  xl create -p domz-p1.cfg 2>&1 | grep -v "^Parsing config"
  ID=$(xl domid DomZ 2>/dev/null)
  echo "DomZ domid=$ID"
  [ -n "$ID" ] || continue
  echo "--- xenstore: virtio backend nodes live under DomD (/local/domain/1)"
  xenstore-ls -f /local/domain/1/backend/virtio/$ID | grep -E "/(base|irq|type|transport|grant_usage) "
  ./qemu-dm -xen-domid $ID -xen-attach -name DomZ -display none -nographic -nodefaults \
    -no-user-config -monitor none -serial none -machine xenpvh -m 16 \
    -global virtio-mmio.force-legacy=false \
    -netdev tap,id=n0,ifname=tapz,script=no,downscript=no \
    -device virtio-net-device,netdev=n0,mac=00:16:3e:5a:00:01 \
    -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-device,rng=rng0 \
    > qemu-dm-$boot.log 2>&1 &
  QPID=$!
  sleep 5
  echo "--- QEMU device model in DomD: pid $QPID, $(cat /proc/$QPID/comm 2>/dev/null || echo DEAD)"
  xl unpause DomZ
  sleep 12
  xl list
  echo "--- DoIP tester (DomD 192.0.2.2 -> EDS in DomZ 192.0.2.1:13400)"
  timeout 60 python3 doip_probe.py 192.0.2.1
  echo "--- DomZ console (Zephyr + EDS, via xenconsoled in DomD)"
  sed 's/\x1b\[[0-9;]*m//g' /var/log/xen/console/guest-DomZ.log | grep -v '^$'
  echo "--- QEMU log"; cat qemu-dm-$boot.log
  xl destroy DomZ 2>/dev/null
  kill $QPID 2>/dev/null; wait $QPID 2>/dev/null
  rm -f /var/log/xen/console/guest-DomZ.log
  echo "=== END BOOT $boot"
done
