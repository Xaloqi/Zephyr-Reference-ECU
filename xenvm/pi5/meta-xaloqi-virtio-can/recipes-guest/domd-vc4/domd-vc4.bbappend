# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
#
# DomD owns the CAN HAT: append the HAT's .dtsi to SoDeV's DomD partial DT
# before domd-vc4.bb's do_compile runs dtc. XAQ_CAN_HAT (conf/layer.conf) picks it:
#   mcp2515    Waveshare 2-CH (isolated) CAN HAT: two MCP2515 on RP1 SPI0
#   mcp2518fd  Waveshare 2-CH CAN FD HAT: MCP2518FD on RP1 SPI0 and on RP1 SPI1
# The .dtsi only refers to labels the .dts defines (&passthrough, &rp1,
# &gpiod0000, &clocks18000), so a SoDeV change that renames one fails dtc here
# instead of silently dropping the HAT.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
XAQ_CAN_HAT_DTSI = "${@ {'mcp2515': 'domd-mcp2515-can.dtsi', 'mcp2518fd': 'domd-mcp2518fd-can.dtsi'}.get(d.getVar('XAQ_CAN_HAT'), '')}"
SRC_URI += "file://${XAQ_CAN_HAT_DTSI}"

python () {
    if not d.getVar('XAQ_CAN_HAT_DTSI'):
        bb.fatal("xaloqi-virtio-can: XAQ_CAN_HAT = '%s', want mcp2515 or mcp2518fd" % d.getVar('XAQ_CAN_HAT'))
}

do_compile:prepend() {
    dts="${UNPACKDIR}/bcm2712-raspberrypi5-domd-vc4.dts"
    # Idempotent: a re-run of do_compile without a fresh unpack must not append twice.
    if ! grep -q 'xaq_rp1_spi0' "$dts"; then
        cat "${UNPACKDIR}/${XAQ_CAN_HAT_DTSI}" >> "$dts"
    fi
}
