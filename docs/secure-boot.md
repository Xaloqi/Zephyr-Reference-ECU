# Secure boot — full procedure

Wires up exactly what EDS ships today: MCUboot swap, the image-policy
gate (SHA-256 digest verify over a DFU transfer), and MCUboot's own
RSA-2048-PSS signature check. Firmware authenticity/anti-rollback beyond
that is [`EDS#319`](https://github.com/Xaloqi/EDS/issues/319), open
upstream and explicitly excluded here — "reference ECU with secure boot"
means this, not building #319 first.

```bash
# 1. One-time: a development signing key (never commit this)
imgtool keygen --key root-rsa-2048.pem --type rsa-2048

# 2. Build and flash MCUboot itself (separate application, own build dir)
BOARD=nucleo_h753zi
KEY=$PWD/root-rsa-2048.pem
OVERLAY=$PWD/boards/nucleo_h753zi_secureboot.overlay
west build -b $BOARD -d build-mcuboot -s bootloader/mcuboot/boot/zephyr -- \
    -DCONFIG_BOOT_SIGNATURE_TYPE_RSA=y \
    "-DCONFIG_BOOT_SIGNATURE_KEY_FILE=\"$KEY\"" \
    -DCONFIG_MCUBOOT_DOWNGRADE_PREVENTION=y \
    "-DDTC_OVERLAY_FILE=$OVERLAY;bootloader/mcuboot/boot/zephyr/app.overlay"
west flash --build-dir build-mcuboot

# 3. Build this ECU with DIAG_SECURE_BOOT_BUILD, then sign it
west build -b $BOARD -d build-app . -- \
    -DDIAG_SKIP_CODEGEN=ON -DDIAG_SECURE_BOOT_BUILD=ON \
    -DEXTRA_CONF_FILE=boards/nucleo_h753zi_secureboot.conf \
    -DDTC_OVERLAY_FILE=$OVERLAY
west sign -t imgtool --build-dir build-app -- --key $KEY --version 1.0.0+0

# 4. Flash the SIGNED image (west flash alone selects the unsigned .hex,
#    which MCUboot will correctly refuse — see below)
west flash --build-dir build-app --hex-file build-app/zephyr/zephyr.signed.hex
```

## Confirmed, both directions, on real hardware — not just the happy path

- The signed image boots: `*** Booting MCUboot v2.1.0 *** ... Jumping to
  the first image slot ***`, then this ECU's own boot log, ending with
  `[DFU] Image policy registered`. Ordinary UDS/CAN diagnostics
  (`TesterPresent`, same as [Run it on a board](../README.md#run-it-on-a-board))
  work identically underneath — the bootloader is transparent to the
  running application.
- **The authenticity gate is real, not a happy-path illusion**: flashing
  the *unsigned* `zephyr.hex` into the same slot gets a genuine refusal —
  `E: Image in the primary slot is not valid! / E: Unable to find
  bootable image` — and MCUboot loops on its own banner rather than
  jumping anywhere. Verified by actually doing it, then reflashing the
  signed image to confirm it boots clean again.
