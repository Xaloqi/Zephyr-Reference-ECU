#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Inside $RUST_IMAGE. /src = this repository (ro), /w = $BUILD/can-spike.
# Clones the backends at the pinned commits, applies patches/, cross-builds for arm64.
set -euo pipefail
source /src/xenvm/can-spike/versions.env
P=/src/xenvm/can-spike/patches; W=/w; mkdir -p $W/src $W/out
apt-get update -qq && apt-get install -y -qq gcc-aarch64-linux-gnu libc6-dev-arm64-cross >/dev/null 2>&1
rustup target add aarch64-unknown-linux-gnu >/dev/null 2>&1
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc CARGO_HOME=$W/cargo-home
git config --global --add safe.directory '*'
clone() { # <dir> <url> <rev> [patch]
  if [ ! -d $W/src/$1/.git ]; then
    git init -q $W/src/$1 && git -C $W/src/$1 fetch -q $2 $3 && git -C $W/src/$1 checkout -q FETCH_HEAD
    [ -z "${4:-}" ] || git -C $W/src/$1 apply $P/$4
  fi
  [ "$(git -C $W/src/$1 rev-parse HEAD)" = "$3" ] || { echo "$1 is not at $3" >&2; exit 1; }
}
clone vhost-device $VHOST_DEVICE_URL $VHOST_DEVICE_REV
clone vireshk-vhost $VHOST_FORK_URL $VHOST_FORK_REV vireshk-vhost-abf24853.patch
clone xen-sys $XEN_SYS_URL $XEN_SYS_REV xen-sys-8a234c94.patch
clone xen-vhost-frontend $XVF_URL $XVF_REV xen-vhost-frontend-a1e333c5.patch
rustc --version
T=aarch64-unknown-linux-gnu
(cd $W/src/vhost-device && cargo build -q --release --locked --target $T -p vhost-device-can -p vhost-device-rng --features vhost-device-can/xen,vhost-device-rng/xen)
(cd $W/src/xen-vhost-frontend && cargo build -q --release --target $T)
cp $W/src/vhost-device/target/$T/release/vhost-device-{can,rng} $W/src/xen-vhost-frontend/target/$T/release/xen-vhost-frontend $W/out/
ls -l $W/out
