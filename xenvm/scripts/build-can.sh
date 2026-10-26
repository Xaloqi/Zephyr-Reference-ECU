# SPDX-License-Identifier: Apache-2.0
# Sourced by scripts/build.sh for `build.sh can`, inside the CAN builder image
# (docker/Dockerfile.can), after the stages both variants share. Builds:
#   out/can/{vhost-device-can,vhost-device-rng,xen-vhost-frontend}  DomD's backends (arm64)
#   out/zephyr-domz-can.bin                                         ReferenceBCM, CAN, for DomZ
# Each set is stamped; run.sh checks both stamps before every boot.

# --- DomD backends: rust-vmm vhost-device + Linaro xen-vhost-frontend --------
# The stamp covers the pins and the patches, so editing or removing a patch
# rebuilds the backends (and a missing patch fails here).
PATCHES="vhost-device-c0bfee92.patch vireshk-vhost-abf24853.patch xen-sys-8a234c94.patch xen-vhost-frontend-a1e333c5.patch"
backends_hash() {
  (cd /src/xenvm && { grep -E '^(RUST_IMAGE|RUST_TOOLCHAIN|VHOST_DEVICE_|XVF_|VHOST_FORK_|XEN_SYS_)' versions.env
                      for p in $PATCHES; do cat patches/$p; done; } | sha256sum | cut -c1-16)
}
CS=$B/can-src; CO=$OUT/can; BSTAMP=$CO/backends.stamp
BWANT="backends=$(backends_hash)"
if [ -f $BSTAMP ] && [ "$(cat $BSTAMP)" != "$BWANT" ]; then
  log "DomD backends are stale (stamp: $(cat $BSTAMP)); rebuilding"
  rm -rf $CS $CO
fi
if [ ! -f $BSTAMP ]; then
  mkdir -p $CS $CO
  clone() { # <dir> <url> <rev> [patch]: a fresh clone at <rev>, with the patch applied
    log "fetch $1 $3${4:+ + patches/$4}"
    rm -rf $CS/$1
    git init -q $CS/$1 && git -C $CS/$1 fetch -q --depth 1 $2 $3 && git -C $CS/$1 checkout -q FETCH_HEAD
    [ "$(git -C $CS/$1 rev-parse HEAD)" = "$3" ] || { echo "$1 is not at $3" >&2; exit 1; }
    if [ -n "${4:-}" ]; then
      [ -f /src/xenvm/patches/$4 ] || { echo "missing patch xenvm/patches/$4" >&2; exit 1; }
      git -C $CS/$1 apply /src/xenvm/patches/$4 || { echo "patch $4 does not apply to $1" >&2; exit 1; }
    fi
  }
  clone vhost-device $VHOST_DEVICE_URL $VHOST_DEVICE_REV vhost-device-c0bfee92.patch
  clone vireshk-vhost $VHOST_FORK_URL $VHOST_FORK_REV vireshk-vhost-abf24853.patch
  clone xen-sys $XEN_SYS_URL $XEN_SYS_REV xen-sys-8a234c94.patch
  clone xen-vhost-frontend $XVF_URL $XVF_REV xen-vhost-frontend-a1e333c5.patch
  log "build DomD backends ($(rustc --version | cut -d' ' -f1-2), aarch64)"
  export CARGO_HOME=$B/cargo CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc
  T=aarch64-unknown-linux-gnu
  (cd $CS/vhost-device && cargo build --release --locked --target $T -p vhost-device-can -p vhost-device-rng \
     --features vhost-device-can/xen,vhost-device-rng/xen) > $B/log-backends.txt 2>&1 \
    || { tail -30 $B/log-backends.txt; exit 1; }
  # The patch carries the Cargo.lock that its [patch] section resolves to.
  (cd $CS/xen-vhost-frontend && cargo build --release --locked --target $T) >> $B/log-backends.txt 2>&1 \
    || { tail -30 $B/log-backends.txt; exit 1; }
  cp $CS/vhost-device/target/$T/release/vhost-device-can $CS/vhost-device/target/$T/release/vhost-device-rng \
     $CS/xen-vhost-frontend/target/$T/release/xen-vhost-frontend $CO/
  echo "$BWANT" > $BSTAMP
fi

# --- Zephyr: ReferenceBCM (CAN) for xenvm, with Xaloqi/zephyr-virtio-can -------
# As for the DoIP image: stamped with the commits compiled and the app's inputs.
CSTAMP=$OUT/zephyr-domz-can.stamp
app_hash_can() { (cd /src && cat prj.conf CMakeLists.txt boards/xenvm_can.conf boards/xenvm_can.overlay src/*.c src/*.h | sha256sum | cut -c1-16); }
PINS="zephyr=$ZEPHYR_REV eds=$EDS_REV virtio-can=$VIRTIO_CAN_REV${XENVM_CAN_ECU_INDEX:+ ecu=$XENVM_CAN_ECU_INDEX}"
WANT="$PINS app=$(app_hash_can)"
if [ -f $OUT/zephyr-domz-can.bin ] && [ "$(cat $CSTAMP 2>/dev/null)" != "$WANT" ]; then
  log "CAN DomZ image is stale or unstamped (stamp: $(cat $CSTAMP 2>/dev/null || echo none)); rebuilding"
  rm -f $OUT/zephyr-domz-can.bin $CSTAMP
fi
if [ ! -f $OUT/zephyr-domz-can.bin ]; then
  west_ws
  log "build ReferenceBCM (CAN, virtio-can) for xenvm"
  # The same prj.conf line as the DoIP build is dropped, for the same reason
  # (STACK_CANARIES is a choice member on Zephyr 4.4; see build.sh).
  grep -v '^CONFIG_STACK_CANARIES=' /src/prj.conf > $B/prj-xenvm-can.conf
  cd $WS
  west build -p always -b xenvm -s /src -d $B/obj-zephyr-can -- \
    -DCONF_FILE=$B/prj-xenvm-can.conf -DDIAG_SKIP_CODEGEN=ON -DDIAG_ENTROPY_SEEDS=ON \
    -DEXTRA_CONF_FILE=boards/xenvm_can.conf \
    -DEXTRA_DTC_OVERLAY_FILE=boards/xenvm_can.overlay \
    ${XENVM_CAN_ECU_INDEX:+-DDIAG_CAN_ECU_INDEX=$XENVM_CAN_ECU_INDEX} > $B/log-zephyr-can.txt 2>&1 \
    || { tail -40 $B/log-zephyr-can.txt; exit 1; }
  C=$B/obj-zephyr-can/zephyr/.config
  for sym in PICOLIBC ENTROPY_GENERATOR ENTROPY_VIRTIO CAN CAN_VIRTIO REBOOT; do
    grep -qx "CONFIG_$sym=y" $C || { echo "  .config: CONFIG_$sym is not y" >&2; exit 1; }
    echo "  .config: CONFIG_$sym=y"
  done
  for sym in NEWLIB_LIBC STACK_CANARIES REQUIRES_STACK_CANARIES EDS_REQUIRE_STACK_CANARIES WATCHDOG \
             TEST_RANDOM_GENERATOR CAN_LOOPBACK NETWORKING; do
    ! grep -qx "CONFIG_$sym=y" $C || { echo "  .config: CONFIG_$sym=y, expected off" >&2; exit 1; }
    echo "  .config: CONFIG_$sym off"
  done
  cp $B/obj-zephyr-can/zephyr/zephyr.bin $OUT/zephyr-domz-can.bin
  echo "zephyr=$(git -C $WS/zephyr rev-parse HEAD) eds=$(git -C $WS/modules/xaloqi-eds rev-parse HEAD)" \
       "virtio-can=$(git -C $WS/modules/zephyr-virtio-can rev-parse HEAD)${XENVM_CAN_ECU_INDEX:+ ecu=$XENVM_CAN_ECU_INDEX}" \
       "app=$(app_hash_can)" > $CSTAMP
fi
