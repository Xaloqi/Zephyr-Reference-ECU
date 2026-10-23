#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
#
# xenvm/run.sh: build everything from pinned versions in a container, boot
# Xen 4.22 + Dom0 + DomD under QEMU, let DomD create DomZ (this ECU, EDS on
# Zephyr 4.4.1) and talk DoIP to it. The last line is PASS or FAIL; the exit
# status matches. Needs Docker and nothing else on the host (no sudo).
#
#   xenvm/run.sh          build what is missing, boot, check
#   xenvm/run.sh boot     boot and check only (artifacts must exist and match the pins)
#   xenvm/run.sh clean    delete the build directory
#
# XENVM_BUILD_DIR overrides the build directory (default: xenvm/build).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
BUILD=${XENVM_BUILD_DIR:-$HERE/build}
source "$HERE/versions.env"
IMAGE=xaloqi-zre-xenvm-builder:1
MODE=${1:-all}

command -v docker >/dev/null || { echo "FAIL: docker not found"; exit 2; }
mkdir -p "$BUILD"
BUILD=$(cd "$BUILD" && pwd)

in_container() { # runs as root inside; files are handed back to the caller's uid
  docker run --rm -v "$REPO":/src:ro -v "$BUILD":/build -e XENVM_BOOT_TIMEOUT \
    "$IMAGE" bash -c "$1; rc=\$?; chown -R $(id -u):$(id -g) /build; exit \$rc"
}

if [ "$MODE" = clean ]; then
  docker run --rm -v "$BUILD":/build "$BASE_IMAGE" sh -c 'rm -rf /build/* /build/.[!.]*' 2>/dev/null || true
  rmdir "$BUILD" 2>/dev/null || true
  echo "removed $BUILD"; exit 0
fi

T0=$(date +%s)
echo "[run] repo $REPO, build dir $BUILD"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[run] building builder image $IMAGE (Debian 13 + cross toolchains + Zephyr SDK $ZSDK_VER)"
  docker build -q -t "$IMAGE" \
    --build-arg BASE_IMAGE="$BASE_IMAGE" --build-arg ZSDK_VER="$ZSDK_VER" \
    --build-arg ZSDK_BASE_URL="$ZSDK_BASE_URL" --build-arg ZSDK_MINIMAL_SHA256="$ZSDK_MINIMAL_SHA256" \
    --build-arg ZSDK_AARCH64_SHA256="$ZSDK_AARCH64_SHA256" --build-arg ZEPHYR_REV="$ZEPHYR_REV" \
    "$HERE/docker" >/dev/null
fi

if [ "$MODE" = all ]; then
  in_container /src/xenvm/scripts/build.sh || { echo "FAIL: build failed (logs: $BUILD/log-*.txt)"; exit 1; }
fi
# The DomZ image must have been built from the commits pinned now. `boot` reuses
# whatever is in the build dir, so without this a pin change passes on the old image.
STAMP_FILE="$BUILD/out/zephyr-domz.stamp"
# Same computation as app_hash in scripts/build.sh.
APP=$(cd "$REPO" && cat prj.conf CMakeLists.txt boards/xenvm_doip.conf boards/xenvm_doip.overlay src/*.c src/*.h | sha256sum | cut -c1-16)
WANT="zephyr=$ZEPHYR_REV eds=$EDS_REV app=$APP"
HAVE=$(cat "$STAMP_FILE" 2>/dev/null || echo "none (no stamp: image built before stamping, or missing)")
if [ "$HAVE" != "$WANT" ]; then
  echo "FAIL: DomZ image was built from [$HAVE], pins and sources are [$WANT]; run xenvm/run.sh (not boot) to rebuild"
  exit 1
fi
in_container /src/xenvm/scripts/boot.sh || { echo "FAIL: boot script failed"; exit 1; }
cp "$BUILD/run/serial.log" "$BUILD/serial.log"

T1=$(date +%s)
echo "[run] wall-clock $(( (T1 - T0) / 60 )) min $(( (T1 - T0) % 60 )) s; build dir $(du -sh "$BUILD" | cut -f1); full log $BUILD/serial.log"
set +e
docker run --rm -v "$REPO":/src:ro -v "$BUILD":/build "$IMAGE" \
  python3 /src/xenvm/scripts/check.py /build/serial.log "$HAVE"
exit $?
