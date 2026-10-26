# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
# CAN HAT drivers, ISO-TP and the xen-vhost-frontend options, built in.
# None of SoDeV's fragments set any of these (checked against dc2755f6), so
# the order relative to their __anonymous-appended fragments does not matter.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://xaloqi-virtio-can.cfg"
