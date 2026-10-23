#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Runs INSIDE the builder container: /src = this repository (read-only),
# /build = the output directory. Builds every piece from the pins in
# xenvm/versions.env. A stage whose output exists is skipped, so a re-run only
# rebuilds what was removed.
set -euo pipefail
source /src/xenvm/versions.env
J=$(nproc)
B=/build
DL=$B/dl; SRC=$B/src; OUT=$B/out
mkdir -p $DL $SRC $OUT
# The build dir is handed back to the caller's uid after each run; root in a
# later container must still be allowed to read those git trees.
git config --global --add safe.directory '*'
log() { echo "[build $(date +%H:%M:%S)] $*"; }
fetch() { # <url> <sha256> -> $DL/<basename>
  local f=$DL/$(basename $1)
  if [ ! -f $f ]; then wget -q -O $f.part $1; mv $f.part $f; fi
  echo "$2  $f" | sha256sum -c --quiet || { echo "checksum mismatch: $f" >&2; exit 1; }
}

# --- Xen 4.22.0, by SHA ---------------------------------------------------
if [ ! -d $SRC/xen/.git ]; then
  log "fetch Xen $XEN_REV"
  git init -q $SRC/xen && git -C $SRC/xen fetch -q --depth 1 $XEN_URL $XEN_REV
  git -C $SRC/xen checkout -q FETCH_HEAD
fi
[ "$(git -C $SRC/xen rev-parse HEAD)" = "$XEN_REV" ] || { echo "Xen is not at $XEN_REV" >&2; exit 1; }

if [ ! -f $OUT/xen ]; then
  log "build Xen hypervisor (arm64 defconfig + EXPERT + IOREQ_SERVER, debug=n)"
  M="make -C $SRC/xen/xen XEN_TARGET_ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-"
  $M defconfig >/dev/null
  printf 'CONFIG_EXPERT=y\nCONFIG_IOREQ_SERVER=y\n' >> $SRC/xen/xen/.config
  $M olddefconfig >/dev/null
  $M -j$J > $B/log-xen.txt 2>&1
  grep -E "^CONFIG_(EXPERT|IOREQ_SERVER|XSM)=" $SRC/xen/xen/.config || true
  cp $SRC/xen/xen/xen $OUT/xen
fi

if [ ! -x $B/xen-tools/usr/sbin/xl ]; then
  log "build Xen tools (arm64, no python bindings)"
  cd $SRC/xen
  sed -i 's/^SUBDIRS-y += python$/# &/' tools/Makefile
  export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig
  ./configure --host=aarch64-linux-gnu --prefix=/usr --sysconfdir=/etc \
    --disable-stubdom --disable-docs --disable-ocamltools --disable-golang \
    --disable-seabios --disable-ipxe --disable-rombios --disable-qemu-traditional \
    --with-system-qemu=/usr/bin/qemu-system-aarch64 --disable-pygrub \
    --with-xenstored=xenstored --disable-systemd > $B/log-xen-tools.txt 2>&1
  make -j$J dist-tools CROSS_COMPILE=aarch64-linux-gnu- XEN_TARGET_ARCH=arm64 PYTHON=python3 \
    QEMU_UPSTREAM_URL= CONFIG_QEMU_XEN=n >> $B/log-xen-tools.txt 2>&1
  rm -rf $B/xen-tools
  make install-tools DESTDIR=$B/xen-tools CROSS_COMPILE=aarch64-linux-gnu- XEN_TARGET_ARCH=arm64 \
    CONFIG_QEMU_XEN=n >> $B/log-xen-tools.txt 2>&1
  unset PKG_CONFIG_LIBDIR
fi

# --- Linux (Dom0 and DomD) --------------------------------------------------
if [ ! -f $OUT/Image ]; then
  log "build Linux $LINUX_VER (arm64 defconfig + xen.config + built-in backends)"
  fetch $LINUX_URL $LINUX_SHA256
  [ -d $SRC/linux-$LINUX_VER ] || tar xf $DL/linux-$LINUX_VER.tar.xz -C $SRC
  M="make -C $SRC/linux-$LINUX_VER ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O=$B/obj-linux"
  $M defconfig xen.config > $B/log-linux.txt 2>&1
  cat /src/xenvm/scripts/linux.config >> $B/obj-linux/.config
  $M olddefconfig >> $B/log-linux.txt 2>&1
  $M -j$J Image >> $B/log-linux.txt 2>&1
  cp $B/obj-linux/arch/arm64/boot/Image $OUT/Image
fi

# --- QEMU as the Xen device model, for DomD ---------------------------------
if [ ! -f $OUT/qemu-dm ]; then
  log "build QEMU $QEMU_VER device model (aarch64, --enable-xen, xenpvh)"
  fetch $QEMU_URL $QEMU_SHA256
  [ -d $SRC/qemu-$QEMU_VER ] || tar xf $DL/qemu-$QEMU_VER.tar.xz -C $SRC
  X=$B/xen-tools/usr; ML=/usr/lib/aarch64-linux-gnu
  # Make the freshly built Xen libraries visible to the cross build (container only).
  cp -a $X/include/. /usr/include/aarch64-linux-gnu/
  cp -a $X/lib/lib*.so* $ML/
  mkdir -p $ML/pkgconfig
  for pc in $X/lib/pkgconfig/*.pc; do
    sed -e "s|^libdir=.*|libdir=$ML|" -e "s|^includedir=.*|includedir=/usr/include/aarch64-linux-gnu|" \
        -e "s|^prefix=.*|prefix=/usr|" $pc > $ML/pkgconfig/$(basename $pc)
  done
  rm -rf $B/obj-qemu; mkdir -p $B/obj-qemu; cd $B/obj-qemu
  PKG_CONFIG_LIBDIR=$ML/pkgconfig:/usr/share/pkgconfig $SRC/qemu-$QEMU_VER/configure \
    --cross-prefix=aarch64-linux-gnu- --target-list=aarch64-softmmu --prefix=/usr \
    --enable-xen --disable-kvm --disable-docs --disable-tools --disable-werror \
    --without-default-features --enable-fdt=system --disable-install-blobs > $B/log-qemu.txt 2>&1
  ninja -j$J qemu-system-aarch64 >> $B/log-qemu.txt 2>&1
  aarch64-linux-gnu-strip -o $OUT/qemu-dm qemu-system-aarch64
fi

# --- Dom0 helper ------------------------------------------------------------
if [ ! -f $OUT/xs-seed-port ]; then
  log "build xs-seed-port"
  X=$B/xen-tools/usr
  aarch64-linux-gnu-gcc -O2 -Wall -o $OUT/xs-seed-port /src/xenvm/harness/xs-seed-port.c \
    -I$X/include -L$X/lib -Wl,-rpath-link,$X/lib -lxenctrl -lxenforeignmemory
fi

# --- Root filesystem shared by Dom0 and DomD ----------------------------------
if [ ! -f $B/rootfs/.done ]; then
  log "build rootfs (Debian $ROOTFS_SUITE arm64, extracted) + Xen tools"
  rm -rf $B/rootfs
  mmdebstrap --mode=root --variant=extract --arch=arm64 --quiet \
    --include=libc6,libfdt1,libncurses6,libtinfo6,libnl-3-200,libnl-route-3-200,libuuid1,libyajl2,zlib1g,busybox-static,bash,iproute2,kmod,libglib2.0-0t64,libpixman-1-0,libaio1t64,libzstd1,libslirp0,libgnutls30t64,libcap-ng0,libpcre2-8-0,libffi8,libmount1,libblkid1,libselinux1,libbpf1,libelf1t64,libmnl0,libcap2,libtirpc3t64,libdb5.3t64,libxtables12,python3-minimal \
    $ROOTFS_SUITE $B/rootfs $ROOTFS_MIRROR
  cp -a $B/xen-tools/. $B/rootfs/
  rm -rf $B/rootfs/usr/share/doc $B/rootfs/usr/share/man $B/rootfs/usr/share/locale \
         $B/rootfs/var/cache/apt $B/rootfs/var/lib/apt/lists
  touch $B/rootfs/.done
fi

# --- Zephyr: ReferenceBCM (DoIP) for xenvm, Zephyr v4.4.1 --------------------
# The image is stamped with the commits it was built from (run.sh checks the stamp
# before every boot). An image whose stamp disagrees with the pins is rebuilt.
# The stamp covers the pinned commits and the app's own inputs (app_hash, the same
# computation as in run.sh), so a conf or source change cannot pass on an old image.
STAMP=$OUT/zephyr-domz.stamp
app_hash() { (cd /src && cat prj.conf CMakeLists.txt boards/xenvm_doip.conf boards/xenvm_doip.overlay src/*.c src/*.h | sha256sum | cut -c1-16); }
PINS="zephyr=$ZEPHYR_REV eds=$EDS_REV"
WANT="$PINS app=$(app_hash)"
if [ -f $OUT/zephyr-domz.bin ] && [ "$(cat $STAMP 2>/dev/null)" != "$WANT" ]; then
  log "DomZ image is stale or unstamped (stamp: $(cat $STAMP 2>/dev/null || echo none)); rebuilding"
  case "$(cat $STAMP 2>/dev/null)" in "$PINS "*) ;; *) rm -rf $B/ws ;; esac
  rm -f $OUT/zephyr-domz.bin $STAMP
fi
if [ ! -f $OUT/zephyr-domz.bin ]; then
  log "west workspace from xenvm/west.yml"
  WS=$B/ws
  if [ ! -d $WS/.west ]; then
    rm -rf $WS; mkdir -p $WS/manifest
    cp /src/xenvm/west.yml $WS/manifest/west.yml
    (cd $WS && west init -l manifest && west update --narrow -o=--depth=1) > $B/log-west.txt 2>&1
  fi
  [ "$(git -C $WS/zephyr rev-parse HEAD)" = "$ZEPHYR_REV" ] || { echo "zephyr is not at $ZEPHYR_REV" >&2; exit 1; }
  [ "$(git -C $WS/modules/xaloqi-eds rev-parse HEAD)" = "$EDS_REV" ] || { echo "EDS is not at $EDS_REV" >&2; exit 1; }
  log "build ReferenceBCM (DoIP) for xenvm"
  # prj.conf asks for CONFIG_STACK_CANARIES=y. On Zephyr 4.4 that symbol is a
  # member of an optional choice, and a later =n (boards/xenvm_doip.conf) does
  # NOT turn the choice off: canaries stay on, seeded by Zephyr's cycle-counter
  # fallback. So this build uses prj.conf minus that one line, and asserts the
  # resulting .config below.
  grep -v '^CONFIG_STACK_CANARIES=' /src/prj.conf > $B/prj-xenvm.conf
  cd $WS
  west build -p always -b xenvm -s /src -d $B/obj-zephyr -- \
    -DCONF_FILE=$B/prj-xenvm.conf \
    -DDIAG_SKIP_CODEGEN=ON -DDIAG_DOIP_ONLY_BUILD=ON -DDIAG_ENTROPY_SEEDS=ON \
    -DEXTRA_CONF_FILE=boards/xenvm_doip.conf \
    -DEXTRA_DTC_OVERLAY_FILE=boards/xenvm_doip.overlay > $B/log-zephyr.txt 2>&1 \
    || { tail -40 $B/log-zephyr.txt; exit 1; }
  # The #4 checklist, asserted on the final configuration (not on the inputs).
  C=$B/obj-zephyr/zephyr/.config
  for sym in PICOLIBC ENTROPY_GENERATOR ENTROPY_VIRTIO ETH_VIRTIO_NET; do
    grep -qx "CONFIG_$sym=y" $C || { echo "  .config: CONFIG_$sym is not y" >&2; exit 1; }
    echo "  .config: CONFIG_$sym=y"
  done
  for sym in NEWLIB_LIBC EDS_REQUIRE_NEWLIB STACK_CANARIES STACK_CANARIES_STRONG STACK_CANARIES_ALL \
             STACK_CANARIES_EXPLICIT REQUIRES_STACK_CANARIES EDS_REQUIRE_STACK_CANARIES WATCHDOG \
             TEST_RANDOM_GENERATOR; do
    ! grep -qx "CONFIG_$sym=y" $C || { echo "  .config: CONFIG_$sym=y, expected off" >&2; exit 1; }
    echo "  .config: CONFIG_$sym off"
  done
  grep -iE "warning:" $B/log-zephyr.txt | sort -u | head -20 || true
  cp $B/obj-zephyr/zephyr/zephyr.bin $OUT/zephyr-domz.bin
  # Stamp from the checkouts that were actually compiled, not from versions.env.
  echo "zephyr=$(git -C $WS/zephyr rev-parse HEAD) eds=$(git -C $WS/modules/xaloqi-eds rev-parse HEAD) app=$(app_hash)" > $STAMP
fi
log "artifacts:"; ls -l $OUT
