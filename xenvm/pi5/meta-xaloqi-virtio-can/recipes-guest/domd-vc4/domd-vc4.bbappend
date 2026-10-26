# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
#
# DomD owns the Waveshare 2-CH CAN HAT: append files/domd-mcp2515-can.dtsi (RP1
# SPI0 + two MCP2515) to SoDeV's DomD partial DT before domd-vc4.bb's
# do_compile runs dtc. The .dtsi only refers to labels the .dts defines
# (&passthrough, &rp1, &gpiod0000, &clocks18000), so a SoDeV change that renames
# one fails dtc here instead of silently dropping the HAT.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI += "file://domd-mcp2515-can.dtsi"

do_compile:prepend() {
    dts="${UNPACKDIR}/bcm2712-raspberrypi5-domd-vc4.dts"
    # Idempotent: a re-run of do_compile without a fresh unpack must not append twice.
    if ! grep -q 'xaq_rp1_spi0' "$dts"; then
        cat "${UNPACKDIR}/domd-mcp2515-can.dtsi" >> "$dts"
    fi
}
