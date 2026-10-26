# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
# CAN HAT drivers, ISO-TP and the xen-vhost-frontend options, built in.
# None of SoDeV's fragments set any of these (checked against dc2755f6), so
# the order relative to their __anonymous-appended fragments does not matter.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://xaloqi-virtio-can.cfg"

# A config fragment option that a dependency drops only gets a warning from
# kernel-yocto's config check, and the build goes on. Fail instead.
XAQ_KERNEL_REQUIRED = "SPI_DESIGNWARE SPI_DW_MMIO CAN CAN_RAW CAN_DEV CAN_MCP251X \
                       CAN_ISOTP CAN_VCAN VIRTIO VIRTIO_MMIO XEN_PRIVCMD XEN_VIRTIO XEN_PRIVCMD_EVENTFD"
do_configure:append() {
    for o in ${XAQ_KERNEL_REQUIRED}; do
        grep -qx "CONFIG_$o=y" ${B}/.config || \
            bbfatal "xaloqi-virtio-can: CONFIG_$o is not =y in ${B}/.config (a dependency dropped it)"
    done
}
