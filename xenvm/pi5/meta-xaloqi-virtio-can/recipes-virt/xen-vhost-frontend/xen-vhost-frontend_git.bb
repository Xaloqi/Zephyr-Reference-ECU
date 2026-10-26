# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
SUMMARY = "Linaro xen-vhost-frontend: Xen ioreq server bridging DomZ's virtio-mmio to vhost-user backends"
DESCRIPTION = "Runs in DomD. Claims DomZ's virtio-mmio slots as an ioreq server, \
foreign-maps DomZ's RAM (grant_usage=0) and hands the vrings to vhost-device-can \
and vhost-device-rng. With the Zephyr-Reference-ECU patches: can/rng devices, \
DriverFeatures read, negotiation on FEATURES_OK, ioreq errors logged, one ioreq \
consumer kicked from userspace, and Xen 4.22's domctl interface 0x18."
HOMEPAGE = "https://github.com/vireshk/xen-vhost-frontend"
LICENSE = "(Apache-2.0 | BSD-3-Clause) & (Apache-2.0 | MIT)"
# xen-vhost-frontend ships no licence file; its Cargo.toml states it. The
# xen-sys crates it links are Apache-2.0 / MIT.
LIC_FILES_CHKSUM = "file://Cargo.toml;beginline=7;endline=7;md5=ea96c82b28de5b9428f7940de22b067b \
                    file://../xen-sys/LICENSE-APACHE;md5=e3fc50a88d0a364313df4b21ef20c29e \
                    file://../xen-sys/LICENSE-MIT;md5=20d7c712894b19d316d7749be10f88cd"

# XVF_REV, VHOST_FORK_REV and XEN_SYS_REV in xenvm/versions.env, each patched
# with its file from xenvm/patches/ (copied verbatim by sodev-add.sh). The
# frontend's patch adds [patch] sections that point at ../vireshk-vhost and
# ../xen-sys, which is why the two are unpacked next to it.
SRC_URI = "git://github.com/vireshk/xen-vhost-frontend.git;protocol=https;nobranch=1;name=xvf;destsuffix=xen-vhost-frontend \
           git://github.com/vireshk/vhost.git;protocol=https;nobranch=1;name=vhost;destsuffix=vireshk-vhost \
           git://github.com/mathieupoirier/xen-sys.git;protocol=https;nobranch=1;name=xensys;destsuffix=xen-sys \
           file://xen-vhost-frontend-a1e333c5.patch \
           file://vireshk-vhost-abf24853.patch;patchdir=../vireshk-vhost \
           file://xen-sys-8a234c94.patch;patchdir=../xen-sys \
          "
SRCREV_xvf = "a1e333c5e358e462e81427c793d291f3a033cf94"
SRCREV_vhost = "abf248531a582d8b04db8cd501d9e5429062e869"
SRCREV_xensys = "8a234c94a5b595e672f9019b2524ee5a98a037a7"
SRCREV_FORMAT = "xvf_vhost_xensys"
PV = "0.1.0+git"
S = "${UNPACKDIR}/xen-vhost-frontend"

inherit cargo

require xen-vhost-frontend-crates.inc

# cargo_common would add its own [patch] for every named git fetch with a
# destsuffix, keyed by the fetch name. The patched Cargo.toml already patches
# both git dependencies by path, and the patched Cargo.lock has no git sources
# left, so that postfunc must not run (it would add wrong crate names).
do_configure[postfuncs]:remove = "cargo_common_do_patch_paths"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/target/${CARGO_TARGET_SUBDIR}/xen-vhost-frontend ${D}${bindir}/
}

COMPATIBLE_HOST = "aarch64.*-linux"
