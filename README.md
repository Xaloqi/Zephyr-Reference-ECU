# Xaloqi Zephyr-Reference-ECU

**A forkable Body Control Module reference application on Zephyr RTOS, with
[Xaloqi EDS](https://github.com/Xaloqi/EDS) wired in as its diagnostics
layer.**

Clone it, build it, run it — one command, no board, no licence:

```bash
west init -l .
west update
west build -b native_sim .
./build/zephyr/zephyr.exe
```

That's a complete, running ECU: door-lock state, a window-position monitor,
two fault conditions, two RoutineControl actuations, and ISO 14229 (UDS)
diagnostics over CAN/ISO-TP — all of it on your laptop, no hardware
required.

---

## What it does

A Body Control Module: it tracks four doors (open/closed), a window
position, and a persisted door-actuation cycle count, and exposes all of
it over UDS. Two DTCs model realistic faults; two RoutineControl
actuations model the kind of commands a real BCM receives.

| | |
|---|---|
| **DIDs** | 7 (3 standard identity, 2 body-state, 1 persisted counter, 1 CDA-interop-only) |
| **DTCs** | 2 |
| **Routines** | 3 (2 application, 1 CDA-interop-only) |
| **Transport** | CAN/ISO-TP and DoIP — see [Run it on a board](#run-it-on-a-board) and [DoIP and secure boot](#doip-and-secure-boot) |
| **RTOS** | Zephyr v3.7.0 |

### DIDs

| ID | Name | Bytes | Access | Notes |
|---|---|---|---|---|
| `0xF190` | VehicleIdentificationNumber | 17 | read | Standard |
| `0xF18C` | ECUSerialNumber | 4 | read | Standard |
| `0xF189` | ECUSoftwareVersionNumber | 4 | read | Standard |
| `0x0410` | BCM_DoorStatus | 1 | read, write | bit0-3 = FL/FR/RL/RR, 1=open. Writable because `native_sim` has no real door sensors — a test campaign *injects* this signal, same pattern as EDS's own [`vehicle_state_ecu`](https://github.com/Xaloqi/EDS/tree/main/examples/vehicle_state_ecu) example |
| `0x0411` | BCM_WindowPosition_pct | 1 | read, write | 0-100%. Same injection pattern |
| `0x0412` | BCM_DoorCycleCount | 4 | read, write | Backed by `src/bcm_storage.c` — see [Storage](#storage) below |
| `0xF100` | Identification | 3 | read | CDA-interop-only, fixed value `0xFF0000` — see [Talk to it with the Eclipse SOVD adapter](#talk-to-it-with-the-eclipse-sovd-adapter) |

### DTCs

| Code | Trigger |
|---|---|
| `0x041064` | Door ajar timeout — a door reported open while `DoorLockAll` has locked the body controller, continuously, past a ~500 ms debounce |
| `0x041165` | Window actuation stall — `BCM_WindowPosition_pct` commanded outside its nominal 0-100 range, past a ~300 ms debounce (stands in for a real motor's current-sense obstruction detection — see `src/bcm_state.c`'s header comment) |

### Routines

| RID | Name | Behaviour |
|---|---|---|
| `0x0420` | DoorLockAll | `start`: locks all doors, arms the door-ajar monitor, increments the persisted cycle count. `results`: `[lock_state, door_status]` |
| `0x0421` | WindowCalibrate | Asynchronous: `start` begins a 4-tick learn-the-end-stops walk; `results` polls `[status, learned_min_pct, learned_max_pct]` |
| `0x1001` | SelfTest | CDA-interop-only stub, no application logic — see [Talk to it with the Eclipse SOVD adapter](#talk-to-it-with-the-eclipse-sovd-adapter) |

### Storage

`BCM_DoorCycleCount` is backed by `src/bcm_storage.c`, persisted through
EDS's own `nvm_store` under an app-defined key — see
[Run it on a board](#run-it-on-a-board) for why that's the right call now
rather than a separate mechanism. **Confirmed surviving a real hardware
reset**, not just built: `DoorLockAll` executed, the count read back
correctly, a hardware reset asserted (not a reflash), and the count read
back unchanged — the boot log shows it restored from NVM before any CAN
traffic that boot. Repeated twice across this session (count 1, then 2),
both times correct.

---

## Make it yours

Rename the ECU in `diagnostics_config.yaml`, change a DID, add your own
signal, run `tools/codegen.py` (from
[Xaloqi EDS](https://github.com/Xaloqi/EDS)) to regenerate `generated/`,
and rebuild.

`src/bcm_state.c` and `src/bcm_storage.c` are the application layer —
door-lock logic, a window monitor, a persisted cycle counter — sitting on
top of EDS, which generates everything else.

---

## Tiers — what is free and what is not

This repo's own code (`src/`, `diagnostics_config.yaml`, `generated/`,
build files, campaigns) is **Apache-2.0** — see `LICENSE`. What it depends
on has a boundary — see `COMMERCIAL_NOTICE.md` for the full table, summarized
here:

| | Free | Needs a licence |
|---|---|---|
| Clone, build, run on `native_sim` | ✅ (`generated/` is pre-committed) | |
| Run the virtual TestLab campaign | ✅ (`xaloqi-tester`, Apache-2.0) | |
| Edit `diagnostics_config.yaml` and **regenerate** `generated/` | | EDS commercial licence (Developer/Professional) |
| Generate the pytest/CAPL test suite alongside the C | | EDS commercial licence — no free path for this half |
| Real CAN/DoIP transport for the TestLab campaign | | `xaloqi-tester-pro` |
| Ship closed-source firmware built on this | | EDS commercial licence (GPL-2.0 otherwise requires releasing your firmware's source) |

**Pre-committed generated C.** `generated/*.c|h` is committed to this repo
so that a forker with no EDS licence can still build and run everything
above the line. This is the exact mechanism EDS's own public examples use
(see EDS's `COMMERCIAL_NOTICE.md`: *"Examples ship their generated C"*) —
copied here, not reinvented.

**The one hand-edited `generated/` file.** `generated/routine_handlers.c`
normally regenerates as empty TODO stubs. This repo's copy delegates its
four RoutineControl bodies to `src/bcm_state.c` instead — the `[APP HOOK]`
markers in that file are exactly what to reapply if you ever regenerate it
from `diagnostics_config.yaml` (a configure-time check in `CMakeLists.txt`
fails the build loudly if a marker goes missing). Same precedent as EDS's
own [`vehicle_state_ecu`](https://github.com/Xaloqi/EDS/tree/main/examples/vehicle_state_ecu)
example, which documents the identical one-file exception.

---

## Run it on a board

```bash
west build -b nucleo_h753zi . -- -DDIAG_SKIP_CODEGEN=ON
west flash
```

Confirmed on real hardware, not simulated: the firmware boots, the UDS
stack reports `6 DIDs 2 DTCs`, and a real `TesterPresent` request sent over
the physical CAN bus (`7DF#023E00`) gets a real positive response
(`7E8#027E00`) — genuine ISO-TP + UDS dispatch on real silicon, not a log
message.

**Resolved, not just worked around.** This board's NVM persistence
(DTC-mirror and `BCM_DoorCycleCount`, above) used to fail outright —
`fs_nvs: Invalid sector size` — because Zephyr's NVS subsystem stores its
sector size in a 16-bit field (max 64 KB) while the STM32H7's native flash
erase sector is 128 KB, a mismatch no value could satisfy, on this chip or
any STM32H7 board. [Xaloqi/EDS#304](https://github.com/Xaloqi/EDS/issues/304)
replaced the backend with an append-only, log-structured store purpose-built
for this sector size, hardware-verified on this exact board family.
`BCM_DoorCycleCount` persisting through a real reset (above) is confirmed
on this repo's own bench. EDS's own DTC-mirror persistence was not
independently re-checked this session — the one attempt made was
confounded by `BCM_DoorStatus` itself being a RAM-only simulated signal
that resets to "closed" on reboot and heals the DTC as a normal
consequence, regardless of whether the underlying NVM record survived.

### Bill of materials

- **NUCLEO-H753ZI** — chosen over the alternative the earlier scoping pass
  considered (FRDM-MCXN947) on two verified facts: 22 EDS example
  references across the H7 Nucleo family (vs. 2), and a working hardware
  bring-up through to host SocketCAN. The FRDM's "onboard CAN PHY" claim
  could not be verified — NXP's own board documentation lists a **SoC**
  feature, not a board one.
- **Waveshare SN65HVD230** 3.3 V CAN transceiver board — a ~€4 commodity
  part, sold in pairs. Named explicitly here so it is never a surprise.
- Wiring: `3.3V`, `GND`, `CAN RX → PD0`, `CAN TX → PD1`, plus the
  termination jumper (both ends of the bus need it).
- A USB-CAN adapter on the host for SocketCAN. Confirmed working: an
  **MKS CANable V2.0 Pro**, which ships slcan firmware (not native
  `gs_usb`) — bridge it with `can-utils`' `slcand`:
  ```bash
  sudo apt-get install -y can-utils
  sudo slcand -o -c -s6 /dev/ttyACM<N> slcan0   # -s6 = 500 kbit/s
  sudo ip link set up slcan0
  ```
- **Ethernet requires jumpers JP6 and JP7 ON** for DoIP over the onboard
  RJ45 — PA2/PB13 conflict with the ST Zio/morpho connectors otherwise
  (Zephyr's own board DTS carries this warning). Leave Ethernet unplugged
  until [DoIP](#doip-and-secure-boot).

---

## Talk to it with the Eclipse SOVD adapter

*Optional — never a dependency.*

```bash
bash scripts/demo_sovd_cda_real_hw.sh
```

With this firmware flashed and `slcan0` (or any host SocketCAN interface)
on the real bus, this one command builds the real Eclipse OpenSOVD Classic
Diagnostic Adapter (CDA) from its own public source (Apache-2.0, cached
after the first run) and proves it talking real SOVD-over-CAN to this
real ECU: discovery, an ISO-TP read, session control, a real AES-128-CMAC
SecurityAccess unlock computed independently against a live seed, and a
real RoutineControl execution — confirmed, not assumed, by actually
running it.

This repo makes no claim of AGL, SoDeV, or Eclipse endorsement or
affiliation. The CDA is used, not contributed to, and never becomes a
dependency — nothing else here requires it.

Two DID/routine entries exist only to interoperate with the CDA's own
fixture data and carry no application logic of their own — the mechanics
of why, and exactly what this does and does not prove (notably: not DoIP,
and not this ECU's own application logic *through* SOVD), are in
[docs/sovd-cda.md](docs/sovd-cda.md).

---

## DoIP and secure boot

**DoIP, not combined with CAN.** (DoIP *with* secure boot is supported, see
[below](#firmware-update-over-doip--signed-image-both-refusals-shown).)
`src/main_doip.c` is a separate,
alternate entry point — `CMakeLists.txt`'s `DIAG_DOIP_ONLY_BUILD` option
selects it *instead of* `src/main.c`, never both in the same image. Xaloqi
EDS ships no example, and no proven architecture, for running CAN and
DoIP concurrently against the same session/security state safely — EDS's
own architecture note designed that ("the diagnostic executor") and
deliberately deferred building it.

```bash
# native_sim (loopback only — reachable from inside the process, not the
# host; a disclosed, pre-existing Zephyr/native_sim limitation, not
# something this repo can fix):
west build -b native_sim . -- -DDIAG_DOIP_ONLY_BUILD=ON \
    -DEXTRA_CONF_FILE=boards/native_sim_doip.conf

# real hardware — needs JP6/JP7 ON and a direct Ethernet link to the host
# (see the bill of materials above):
west build -b nucleo_h753zi . -- -DDIAG_SKIP_CODEGEN=ON -DDIAG_DOIP_ONLY_BUILD=ON \
    -DEXTRA_CONF_FILE=boards/nucleo_h753zi_doip.conf
west flash
```

**Confirmed on `native_sim`**: boots and runs correctly (`UDS stack ready:
7 DIDs 2 DTCs`, DoIP listening on port 13400).

**Confirmed on real hardware** (NUCLEO-H753ZI, direct Ethernet link):
routing activation, DID reads, extended session, AES-CMAC SecurityAccess,
`DoorLockAll`, and `BCM_DoorCycleCount` read back after a real reset. A
tester may now pause between requests: the session and SecurityAccess
unlock hold across a 2 s TesterPresent cadence. Before
[`EDS#400`](https://github.com/Xaloqi/EDS/issues/400) the connection was
dropped after ~150 ms of silence. The ECU is reachable about 3.5–4 s after
reset. The console is on the ST-LINK VCP; on a typical Linux host that
enumerated as `/dev/ttyACM2`, not `ttyACM0`, and a wrong port looks exactly
like a dead board.

The earlier "silent board" was an unfed watchdog, not a power
problem — history in
[`#7`](https://github.com/Xaloqi/Zephyr-Reference-ECU/issues/7).

**Watchdog: the UDS tick path and the DoIP server loop are supervised.**
The IWDG is armed in `main()` and fed only from the UDS tick task. It
feeds only while the DoIP server loop has checked in recently, through
EDS's `eds_doip_set_checkin_callback()`
([`EDS#399`](https://github.com/Xaloqi/EDS/issues/399)). A hung tick loop,
a request dispatch hung while holding the UDS locks, or a DoIP server
thread wedged on its socket or exited all reset the ECU. An idle server
with no client checks in every 5 s and is not reset. A dead Ethernet link
is not detected. Boot before `main()` (which waits 1.5–4.1 s for the network)
is unsupervised. One exception, in the secure-boot variant only: while a
firmware download's erase step or 0x37 read-back is running, a timer in
EDS's flash ops also feeds the watchdog (see [below](#firmware-update-over-doip--signed-image-both-refusals-shown)).
The exact claim is in `src/main_doip.c`'s header; read it before relying
on more.

**ECUReset over DoIP resets.** Before
[`EDS#434`](https://github.com/Xaloqi/EDS/issues/434), `11 01` answered
`51 01` and the ECU kept running, because no DoIP path performed the
deferred reset. EDS's DoIP server now performs it through its platform
binding (flush, 50 ms grace, reset).

### Secure boot — confirmed working, both directions

MCUboot swap, a SHA-256 image-policy gate, and MCUboot's own RSA-2048-PSS
signature check. Firmware authenticity/anti-rollback beyond that is
[`EDS#319`](https://github.com/Xaloqi/EDS/issues/319), open upstream and
explicitly out of scope here — "reference ECU with secure boot" means
this, not building #319 first.

- **The signed image boots clean**, and ordinary UDS/CAN diagnostics
  (`TesterPresent`, same as [above](#run-it-on-a-board)) work identically
  underneath — the bootloader is transparent to the running application.
- **The authenticity gate is real, not a happy-path illusion**: flashing
  the *unsigned* image into the same slot gets a genuine refusal (`Image
  in the primary slot is not valid!`), and MCUboot loops on its own
  banner rather than jumping anywhere. Verified by actually doing it, then
  reflashing the signed image to confirm it recovers.

Full key-generation, build, sign and flash procedure:
[docs/secure-boot.md](docs/secure-boot.md).

### Firmware update over DoIP — signed image, both refusals shown

`-DDIAG_DOIP_ONLY_BUILD=ON -DDIAG_SECURE_BOOT_BUILD=ON` builds DoIP with
secure boot. `scripts/doip_flash.py` runs `10 02`, `27`, `34` (the erase runs
behind `7F 34 78`), `36` ×N, `37` with CRC-32, then `11 01`. Confirmed on a
NUCLEO-H753ZI with real Ethernet ([EDS#425](https://github.com/Xaloqi/EDS/issues/425)):

| Image (512,336 B signed) | 0x37 (EDS image policy) | MCUboot after `11 01` | Running afterwards |
|---|---|---|---|
| Correctly signed, v1.1.0 | `77` accepted | swapped, booted, confirmed | v1.1.0 |
| Signed with the **wrong key**, v1.2.0 | `77` accepted | **refused**: `Image in the secondary slot is not valid!` | v1.1.0 (unchanged) |
| Correctly signed, **one payload byte flipped**, v1.3.0 | **refused**: `7F 37 72`, digest mismatch | `Swap type: none` | v1.1.0 (unchanged) |

The two refusals are different guarantees. EDS's 0x37 check is a digest
check, so it catches corruption and naive tampering. **Authenticity comes
only from MCUboot's signature check, at swap time.** An image with a
recomputed digest and no valid signature passes 0x37, as the wrong-key row
shows.

- **Timing:** 500 KiB in 7.2 s (erase 3.3 s, 2010 × 0x36 at a median 1.91 ms
  each). 2 MiB of TransferData plus 16 sector erases ran on one connection in
  29 s, 1.6 % of the 30 min connection lifetime.
- **Largest image: 512 KiB including header and TLVs.** MCUboot's
  swap-using-move needs one free sector plus the trailer sector in each 6 ×
  128 KB slot. No dual-slot layout of this part's 2 MB internal flash holds a
  1 MB image.
- **Watchdog:** RCC_RSR 0 and IWDG1 RLR 0x031F, sampled every 0.5 s through
  each download. While an erase step or the 0x37 read-back runs, a timer
  feeds the watchdog, bounded by the flash driver's 8 s timeout. MCUboot's
  swap runs before `main()` and is unsupervised (~19 s from reset to an
  armed IWDG). `src/main_doip.c`'s header has the exact statement.

Commands and the full campaign: [docs/secure-boot.md](docs/secure-boot.md#firmware-update-over-doip).

---

## As a Xen guest: AGL SoDeV's DomZ, over DoIP

`xenvm/run.sh` builds Xen 4.22, two Linux domains, QEMU and this ECU (DoIP build,
Zephyr 4.4.1 `xenvm`), all in a container, and boots them under QEMU. A dom0less driver
domain (DomD) creates DomZ from SoDeV's `domz.cfg`, backs its virtio-net and
virtio-rng, and runs a DoIP tester against it. The script needs Docker only and ends
in PASS or FAIL. The NUCLEO builds above stay on Zephyr v3.7.0; this variant has its
own manifest, [xenvm/west.yml](xenvm/west.yml).

What it proves and what it leaves out (no grant isolation, entropy from the backend
domain, no watchdog, no canaries, placeholder keys): [xenvm/README.md](xenvm/README.md).

---

## What CI does and does not prove

Three independent jobs (`.github/workflows/ci.yml`):

0. **`unit-tests`** — runs `tests/test_bcm_debounce.c` (plain gcc, no
   Zephyr, no EDS). This is the one module in `src/` with no Zephyr/EDS
   dependency at all; the rest of `src/` only compiles inside the full
   west/Zephyr build, so it's proven by the job below instead, not by a
   host unit test.
1. **`zephyr-native`** — builds this ECU for `native_sim` and boots it for
   3 seconds, confirming the UDS stack initializes. This proves the
   firmware **builds and links against real EDS**, nothing more. It does
   not exchange a single UDS frame.
2. **`virtual-campaign`** — runs `campaigns/reference_bcm.yaml` with the
   free `xaloqi-tester --virtual`. This proves the campaign mechanics and
   the wire-level DID/routine/DTC surface work, **against a small built-in
   simulator, not this ECU's real firmware.** Verified directly, not
   assumed: the free tier's `--virtual` ECU starts with four hardcoded
   standard DIDs and no others, and answers RoutineControl for any RID
   without running this ECU's actual logic — see
   `campaigns/reference_bcm.yaml`'s own header comment for exactly what
   that means for every step in it.

**None of these jobs runs the real firmware over real CAN, DoIP, or
through a bootloader.** That was all done manually, on the bench — see
[Run it on a board](#run-it-on-a-board) and
[DoIP and secure boot](#doip-and-secure-boot) above. There is no
hardware-in-the-loop runner, and nothing re-verifies any of it on every
push.

**The full CAN diagnostic surface has been exercised for real, on the
bench, over the physical bus** — raw ISO-TP frames (`can-utils`'
`isotpsend`/`isotprecv`, free, no Pro transport needed) and a real
AES-128-CMAC SecurityAccess unlock computed independently against a live
seed:

- **Both DTC monitors, set and healed.** Door-ajar set with the exact
  status bits `bcm_state.c` defines (`59 02 FF 04 10 64 0B`), then cleared
  on closing the door. Window-stall set by writing an out-of-range
  position (`0xFF`), then cleared by writing a valid one back.
- **Both routines.** `DoorLockAll`, and `WindowCalibrate`'s full
  asynchronous walk — `start` acknowledged, polled ~0.5 s later, returned
  `[PASS, learned_min=0, learned_max=100]`.
- **All 6 DIDs read.** The three standard identity DIDs return the
  generated stub's deterministic zeros (same as every EDS example until
  an integrator replaces the stub). `BCM_DoorCycleCount` read back `1`
  correctly after one earlier `DoorLockAll` — see [Storage](#storage) for
  why it won't survive a reset yet.

Not yet exercised this way: DID write-then-fault-clear for the identity
DIDs (not applicable — they're read-only). A reset/reboot cycle *was*
exercised, separately — see [Storage](#storage) — confirming
`BCM_DoorCycleCount` specifically; it does not speak to DTC-mirror
persistence, which that same check could not cleanly isolate (see
[Run it on a board](#run-it-on-a-board)).

---

## Licence

This repository's own code: **Apache-2.0** (`LICENSE`). What it depends on
has its own, different licence — see `COMMERCIAL_NOTICE.md` before you
assume anything here is free to regenerate or re-license.
