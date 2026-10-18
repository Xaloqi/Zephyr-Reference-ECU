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

## Firmware update over DoIP

DoIP plus secure boot, verified on NUCLEO-H753ZI with a direct Ethernet link
(host `10.10.10.2/24`, JP6/JP7 on, see [README](../README.md#doip-and-secure-boot)).
MCUboot is built and flashed as in steps 1–2 above.

```bash
# 3'. Build the DoIP + secure-boot variant, sign it, flash it (v1.0.0)
west build -b $BOARD -d build-app . -- \
    -DDIAG_SKIP_CODEGEN=ON -DDIAG_DOIP_ONLY_BUILD=ON -DDIAG_SECURE_BOOT_BUILD=ON \
    "-DEXTRA_CONF_FILE=boards/nucleo_h753zi_doip.conf;boards/nucleo_h753zi_secureboot.conf" \
    -DDTC_OVERLAY_FILE=$OVERLAY
west sign -t imgtool --build-dir build-app -- --key $KEY --version 1.0.0+0
west flash --build-dir build-app --hex-file build-app/zephyr/zephyr.signed.hex

# 4'. Sign a newer image and download it over DoIP (needs: pip install xaloqi-tester)
west sign -t imgtool --build-dir build-app -- --key $KEY --version 1.1.0+0
python3 scripts/doip_flash.py build-app/zephyr/zephyr.signed.bin --reset
```

`doip_flash.py` prints each phase's time and the 0x36 round-trip
distribution, and exits non-zero on the first negative response, naming it.
After `11 01`, MCUboot swaps the image in (~15 s for 500 KiB), and the new
image confirms itself at boot (`[OTA] New image confirmed`).

**Largest image: 524,288 B (512 KiB) including the 1 KiB header and the
TLVs.** MCUboot's swap-using-move (`swap_move.c`, `swap_run()`) needs the
image to end before the sector before the trailer sector. With 6 × 128 KB
sectors per slot that leaves 4. Since EDS#479 the ECU advertises exactly
that as its download region (boot log: `Download region: 524288 B`), so 0x34
answers `7F 34 31` for a larger image. Before, such an image passed 0x34–0x37,
then MCUboot logged `Not enough free space to run swap upgrade` and kept the
old image ([EDS#436](https://github.com/Xaloqi/EDS/issues/436)).

**The CAN build downloads too** (#19). Same sequence over CAN at 500 kbit/s
(requests on 0x7DF, responses on 0x7E8): on 2026-10-18 a signed 108,740 B
v1.1.0 image went through 0x34 (erase answered `7F 34 78`, then `74`),
425 × 0x36 in 38 s, `37 <CRC-32>` → `77`, and `11 01`; MCUboot swapped it
in and it confirmed itself. The TransferData block counter wraps
0xFF → 0x00. No dual-slot
layout of this part's 2 MB internal flash holds a 1 MB image.

### Larger images: the arithmetic, and two routes

The limit comes from MCUboot's swap geometry on this part, not from EDS or
the DoIP path. The STM32H753's 2 MB is sixteen 128 KB sectors:

| Layout (sectors of 128 KB) | Per slot | Largest image under swap-using-move |
|---|---|---|
| This repo: MCUboot 2 + slots 6 + 6 + `diag_nvs` 2 | 768 KB | 4 sectors = **512 KiB** |
| Stripped: MCUboot 1, no NVS, slots 7 + 7 (+1 spare) | 896 KB | 5 sectors = 640 KiB |

Swap-using-move gives up one sector per slot for the move, and the trailer
needs its own sector at the end. So the largest image is the slot minus two
sectors. Every dual-slot layout of 2 MB of internal flash stays under 1 MB.
`diag_nvs` can't shrink: two banks of one sector each is the minimum that
keeps the SecurityAccess lockout counter safe across power loss (see EDS#304).

An image of 1 MB or more needs one of two designs. They're different update
architectures, not configuration changes:

1. **Secondary slot in external flash** (QSPI/OSPI NOR; NUCLEO-H753ZI has
   none). The primary slot can then take all internal flash not used by
   MCUboot and `diag_nvs`, at most 12 sectors (1.5 MB) on this part, minus
   what the chosen upgrade mode reserves. Rollback is kept. Check which
   upgrade modes MCUboot supports for the external part's sector size
   before sizing: swap-using-move expects matching sector geometry.
2. **Single application slot** (MCUboot `SINGLE_APPLICATION_SLOT`, or
   `BOOT_FIRMWARE_LOADER` with a small separate loader image). The
   application gets almost all of the internal flash, but **there is no
   previous image to revert to**: an interrupted or rejected update leaves
   the ECU in the bootloader or loader, not on the old firmware. For an
   ASIL-B-positioned ECU that's a safety-concept decision, not a size tweak.

The download path (DoIP, image policy, watchdog bridging, S3) doesn't
depend on the image size. Erase scales at ~0.83 s per 128 KB sector
(≤ 4 s worst case, inside `DOIP_MAX_PENDING_MS`), and 2 MiB of
TransferData ran on one connection in 29 s.

### Confirmed on hardware, including both refusals

Each image is the application padded to 500 KiB (512,336 B signed). The
wrong-key and tampered images carry higher versions than the running one,
so downgrade prevention can't be what rejects them.

| Image | 0x37 | MCUboot after `11 01` | Running afterwards |
|---|---|---|---|
| Correctly signed, v1.1.0 | `77` | `Swap type: test` → swap, boot, confirm | v1.1.0 |
| Wrong key (`imgtool keygen`, second key), v1.2.0 | `77` | `E: Image in the secondary slot is not valid!`, secondary erased | v1.1.0 |
| Correct key, byte at file offset 0x2400 flipped after signing, v1.3.0 | `7F 37 72`, `SHA-256 digest mismatch` | `Swap type: none` (after a separate `11 01`) | v1.1.0 |

Where each refusal happens matters. EDS's image policy is **digest-only**:
it recomputes MCUboot's SHA-256 over header and body and compares it with
the image's own TLV. That catches corruption and naive tampering at 0x37,
before anything is armed. **Authenticity comes only from MCUboot's
RSA-2048-PSS check at swap time.** The wrong-key image is internally
consistent, so EDS accepts it and MCUboot refuses it. So does any image whose
digest an attacker recomputed. In both refusals the old image keeps running.

Timing (500 KiB, one connection): 0x34 3.3 s (4 sector erases behind
`7F 34 78`), 2010 × 0x36 in 3.8 s (median 1.91 ms, p99 1.97 ms per request),
0x37 0.05 s, 7.2 s in total. Four such downloads back to back on one
connection (2 MiB of TransferData, 16 erases) took 29 s, 1.6 % of
`DOIP_MAX_CONNECTION_LIFETIME_MS` (30 min). At the devicetree's worst-case
erase time (4 s per sector) a 2 MB region needs 64 s of erase, inside
`DOIP_MAX_PENDING_MS` (120 s).

Watchdog, measured the usual way (clear RCC_RSR, free-run, halt, read)
**and** sampled every 0.5 s during each download: RCC_RSR `0x00000000` and
IWDG1 RLR `0x031F` throughout erase, transfer and verify. After `11 01`,
RSR shows the software-reset flag, never IWDG1RSTF. RLR reads `0x0FFF`
while MCUboot and the pre-`main()` network wait run, then `0x031F` once the
new image arms it.
