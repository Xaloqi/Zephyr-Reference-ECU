# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
SUMMARY = "DomZ-CAN for the Pi 5 bench: ReferenceBCM (EDS) on virtio-can, and its DomD tooling"
DESCRIPTION = "Installs into DomD: the DomZ-CAN Zephyr image (Zephyr-Reference-ECU's \
CAN build for xenvm, ISO 15765-4 ECU 1, built by xenvm/run.sh can and staged by \
sodev-add.sh), the bench driver xaloqi-can-bench, the stdlib testers (ISO-TP probe, \
wire dump, P2 timing) and the xenstore socket relay xen-vhost-frontend needs in a \
driver domain."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

# zephyr-domz-can.bin and zephyr-domz-can.stamp are not in git: sodev-add.sh copies
# them from the xenvm build (out/), and the stamp records the pins it was built from.
# isotp_probe.py, can_dump.py and xs-sock-relay.py are copied from xenvm/harness/.
SRC_URI = " \
    file://zephyr-domz-can.bin \
    file://zephyr-domz-can.stamp \
    file://xaloqi-can-bench \
    file://uds_timing.py \
    file://isotp_probe.py \
    file://can_dump.py \
    file://xs-sock-relay.py \
"
S = "${UNPACKDIR}"

do_compile() {
    # Refuse an image that is not ECU 1 (DIAG_CAN_ECU_INDEX=1): on the shared bus
    # it would collide with the NUCLEO on 0x7E0/0x7E8.
    grep -q ' ecu=1 ' ${S}/zephyr-domz-can.stamp || \
        bbfatal "zephyr-domz-can.bin is not built as ECU 1: $(cat ${S}/zephyr-domz-can.stamp)"
}

do_install() {
    install -d ${D}/usr/lib/xen/boot ${D}${libexecdir}/xaloqi-can ${D}${bindir} ${D}${datadir}/xaloqi-can
    install -m 0644 ${S}/zephyr-domz-can.bin ${D}/usr/lib/xen/boot/zephyr-domz-can.bin
    install -m 0644 ${S}/zephyr-domz-can.stamp ${D}${datadir}/xaloqi-can/zephyr-domz-can.stamp
    install -m 0755 ${S}/xaloqi-can-bench ${D}${bindir}/xaloqi-can-bench
    for f in uds_timing.py isotp_probe.py can_dump.py xs-sock-relay.py; do
        install -m 0755 ${S}/$f ${D}${libexecdir}/xaloqi-can/$f
    done
}

FILES:${PN} = "/usr/lib/xen/boot/zephyr-domz-can.bin ${libexecdir}/xaloqi-can ${bindir}/xaloqi-can-bench ${datadir}/xaloqi-can"
# The Zephyr image is a bare-metal arm64 binary for Xen, not a Linux ELF.
INSANE_SKIP:${PN} += "arch already-stripped"

RDEPENDS:${PN} = "python3-core python3-io can-utils iproute2 \
                  vhost-device-can vhost-device-rng xen-vhost-frontend"
