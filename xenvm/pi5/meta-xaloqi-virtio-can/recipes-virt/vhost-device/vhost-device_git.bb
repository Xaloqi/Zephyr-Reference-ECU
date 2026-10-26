# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
SUMMARY = "rust-vmm vhost-user backends for DomZ: vhost-device-can and vhost-device-rng"
DESCRIPTION = "vhost-device-can serves DomZ's virtio-can on a SocketCAN interface of \
DomD (the MCP2515 HAT's can0); vhost-device-rng serves its virtio-rng. Built with \
the xen feature, for xen-vhost-frontend's foreign mapping. Same pin and patch as \
Zephyr-Reference-ECU xenvm/run.sh can (xenvm/versions.env, xenvm/patches/)."
HOMEPAGE = "https://github.com/rust-vmm/vhost-device"
LICENSE = "Apache-2.0 | BSD-3-Clause"
LIC_FILES_CHKSUM = "file://LICENSE-APACHE;md5=3b83ef96387f14655fc854ddc3c6bd57 \
                    file://LICENSE-BSD-3-Clause;md5=2489db1359f496fff34bd393df63947e"

# VHOST_DEVICE_REV in xenvm/versions.env. The patch is upstream PR #924 (RX
# buffers lost until RX stops, rust-vmm/vhost-device#923), copied verbatim from
# xenvm/patches/ by sodev-add.sh.
SRC_URI = "git://github.com/rust-vmm/vhost-device.git;protocol=https;nobranch=1;destsuffix=vhost-device \
           file://vhost-device-c0bfee92.patch \
          "
SRCREV = "c0bfee92d28ffa7199ebe894c16d877a6f216fc3"
PV = "0.1.0+git"
S = "${UNPACKDIR}/vhost-device"

inherit cargo

require vhost-device-crates.inc

# A workspace: build only the two backends DomZ uses, with Xen support.
CARGO_BUILD_FLAGS += "-p vhost-device-can -p vhost-device-rng \
                      --features vhost-device-can/xen,vhost-device-rng/xen"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/target/${CARGO_TARGET_SUBDIR}/vhost-device-can ${D}${bindir}/
    install -m 0755 ${B}/target/${CARGO_TARGET_SUBDIR}/vhost-device-rng ${D}${bindir}/
}

PACKAGES =+ "vhost-device-can vhost-device-rng"
FILES:vhost-device-can = "${bindir}/vhost-device-can"
FILES:vhost-device-rng = "${bindir}/vhost-device-rng"

COMPATIBLE_HOST = "aarch64.*-linux"
