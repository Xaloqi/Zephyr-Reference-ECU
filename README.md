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

## Now make it yours

The point of this repo is not that it works out of the box. **A reference
ECU whose diagnostics already work perfectly is the least useful version of
this idea** — you clone it, you're impressed, you leave.

So: rename the ECU in `diagnostics_config.yaml`, change a DID, add your own
signal, run `tools/codegen.py` (from [Xaloqi EDS](https://github.com/Xaloqi/EDS))
to regenerate `generated/`, and rebuild. That path is the real point of this
repo — it leads straight to the commercial boundary (see
[Tiers](#tiers--what-is-free-and-what-is-not) below), by design, with no
sales pitch in the way.

**Diagnostics is a component here, not the subject.** `src/bcm_state.c` and
`src/bcm_storage.c` are the application — door-lock logic, a window
monitor, a persisted cycle counter. EDS is the part that is supposed to
just work so you don't have to think about it, until the moment you change
a DID.

---

## What this is

A Body Control Module: it tracks four doors (open/closed), a window
position, and a persisted door-actuation cycle count, and exposes all of it
over UDS. Two DTCs model realistic faults; two RoutineControl actuations
model the kind of commands a real BCM receives.

| | |
|---|---|
| **DIDs** | 7 (3 standard identity, 2 body-state, 1 persisted counter, 1 CDA-interop-only — Phase 3) |
| **DTCs** | 2 |
| **Routines** | 3 (2 application, 1 CDA-interop-only — Phase 3) |
| **Transport** | CAN / ISO-TP — loopback on `native_sim`, real CAN confirmed on `nucleo_h753zi` (Phase 2) |
| **RTOS** | Zephyr v3.7.0 |

### DIDs

| ID | Name | Bytes | Access | Notes |
|---|---|---|---|---|
| `0xF190` | VehicleIdentificationNumber | 17 | read | Standard |
| `0xF18C` | ECUSerialNumber | 4 | read | Standard |
| `0xF189` | ECUSoftwareVersionNumber | 4 | read | Standard |
| `0x0410` | BCM_DoorStatus | 1 | read, write | bit0-3 = FL/FR/RL/RR, 1=open. Writable because `native_sim` has no real door sensors — a test campaign *injects* this signal, same pattern as EDS's own [`vehicle_state_ecu`](https://github.com/Xaloqi/EDS/tree/main/examples/vehicle_state_ecu) example |
| `0x0411` | BCM_WindowPosition_pct | 1 | read, write | 0-100%. Same injection pattern |
| `0x0412` | BCM_DoorCycleCount | 4 | read, write | Backed by `src/bcm_storage.c` — see [Storage](#storage) |
| `0xF100` | Identification | 3 | read | CDA-interop-only, fixed value `0xFF0000` — see [Phase 3](#phase-3--eclipse-opensovd-cda-interop-optional-never-a-dependency) |

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
| `0x1001` | SelfTest | CDA-interop-only stub, no application logic — see [Phase 3](#phase-3--eclipse-opensovd-cda-interop-optional-never-a-dependency) |

---

## Storage

`src/bcm_storage.c` is the persistence boundary for the door-cycle counter —
separate from EDS's own NVM store, which belongs to the diagnostics layer
(the DTC mirror) and is not this module's concern.

**Still a RAM-backed stub on real hardware, too.** The plan was for Phase 2
to back this with a flash-backed settings partition. It can't yet: the
same NVS/128 KB-sector incompatibility documented under
[Phase 2](#phase-2--real-hardware) ([`EDS#304`](https://github.com/Xaloqi/EDS/issues/304))
blocks this module exactly as it blocks EDS's own DTC mirror — there is no
working flash-backed persistence primitive on this board to build on yet.
The API (`bcm_storage_init`, `bcm_storage_load_door_cycle_count`,
`bcm_storage_save_door_cycle_count`) is the real, permanent boundary;
only the backing implementation changes once that's resolved upstream.

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

**None of these jobs runs the real firmware over real CAN.** That was done
once, manually, on the bench (see Phase 2 below) — it is not a CI job,
there is no hardware-in-the-loop runner, and nothing re-verifies it on
every push.

**The full diagnostic surface has been exercised for real, on the bench,
over the physical bus** — raw ISO-TP frames (`can-utils`' `isotpsend`/
`isotprecv`, free, no Pro transport needed) and a real AES-128-CMAC
SecurityAccess unlock computed independently against a live seed:

- Both DTC monitors, set and healed. Door-ajar: `DoorLockAll` executed,
  `BCM_DoorStatus` written open, DTC `0x041064` confirmed set
  (`59 02 FF 04 10 64 0B` — the exact status bits `bcm_state.c` sets) after
  the debounce window, then cleared on closing the door. Window-stall:
  `BCM_WindowPosition_pct` written out of range (`0xFF`), DTC `0x041165`
  confirmed set, then cleared on writing a valid position back.
- Both routines. `DoorLockAll` (above) and `WindowCalibrate`'s full
  asynchronous walk — `start` acknowledged, `requestRoutineResults` polled
  ~0.5 s later and returned `[PASS, learned_min=0, learned_max=100]`,
  matching `bcm_state.c`'s design exactly.
- All 6 DIDs read. The three standard identity DIDs return the generated
  stub's deterministic zeros (not yet wired to anything — same as every
  EDS example until an integrator replaces the stub). `BCM_DoorCycleCount`
  correctly read back `1` after one earlier `DoorLockAll`, persisting
  correctly in RAM across every exchange in this session (see
  [Storage](#storage) for why it won't survive a reset yet).

Not yet exercised this way: DID write-then-fault-clear for the identity
DIDs (not applicable — they're read-only) and a reset/reboot cycle.

**No secure-boot claim.** EDS ships MCUboot swap and a fail-closed
image-policy gate, but firmware authenticity/anti-rollback
([`EDS#319`](https://github.com/Xaloqi/EDS/issues/319)) is open upstream.
This repo makes no secure-boot claim of any kind in this phase.

---

## Phase 2 — real hardware

```bash
west build -b nucleo_h753zi . -- -DDIAG_SKIP_CODEGEN=ON
west flash
```

Confirmed on real hardware, not simulated: the firmware boots, the UDS
stack reports `6 DIDs 2 DTCs`, and a real `TesterPresent` request sent over
the physical CAN bus (`7DF#023E00`) gets a real positive response
(`7E8#027E00`) — genuine ISO-TP + UDS dispatch on real silicon, not a log
message.

**One real, known limitation.** DTC-mirror persistence fails to initialize
on this board: `fs_nvs: Invalid sector size`. Root cause, already filed and
root-caused upstream as [Xaloqi/EDS#304](https://github.com/Xaloqi/EDS/issues/304):
Zephyr's NVS subsystem stores its sector size in a 16-bit field (max
64 KB), but the STM32H7's native flash erase sector is 128 KB — no value
satisfies both constraints, on this chip or any STM32H7 board. Non-fatal
(the firmware logs the error and continues, same as EDS's own
`safeboot_ecu`) — DTCs still work over this boot, they just don't survive
a reset. Our own `src/bcm_storage.c` cycle-count persistence is blocked on
the identical root cause and stays a documented RAM stub until EDS
resolves it.

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
  termination jumper (both ends of the bus need it — see below).
- A USB-CAN adapter on the host for SocketCAN. Confirmed working: an
  **MKS CANable V2.0 Pro**, which ships slcan firmware (not native
  `gs_usb`) — bridge it with `can-utils`' `slcand`:
  ```bash
  sudo apt-get install -y can-utils
  sudo slcand -o -c -s6 /dev/ttyACM<N> slcan0   # -s6 = 500 kbit/s
  sudo ip link set up slcan0
  ```
- **Ethernet requires jumpers JP6 and JP7 ON** if a future phase adds DoIP
  over the onboard RJ45 — PA2/PB13 conflict with the ST Zio/morpho
  connectors otherwise (Zephyr's own board DTS carries this warning). Not
  needed for anything in this phase — leave Ethernet unplugged.

A documented part is an instruction; an undocumented one is friction.

---

## Phase 3 — Eclipse OpenSOVD CDA interop (optional, never a dependency)

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
running it. This absorbs
[Xaloqi/EDS's own BUILD-1 capability](https://github.com/Xaloqi/EDS/blob/main/scripts/demo_can_sovd_cda_interop.sh)
(the script and this capability are otherwise identical) retargeted at
this repo's real hardware instead of EDS's `native_sim` + `vxcan`.

**This repo makes no claim of AGL, SoDeV, or Eclipse endorsement or
affiliation** of any kind. Connecting to the CDA needs no permission —
it's used, not contributed to, and never becomes a dependency: nothing
else in this repo requires it, and if the CDA breaks across its own
pre-1.0 releases, this repo does not break with it.

**Two disclosed CDA-interop-only entries**, same honesty policy as EDS's
own precedent: DID `0xF100` ("Identification", fixed value `0xFF0000`)
selects the CDA's own shipped `FLXC1000.mdd` fixture's `Boot_Variant` —
without it the CDA has no SecurityAccess service to route to at all.
Routine `0x1001` ("SelfTest") exists only because SOVD resolves
`/operations/<name>` against whatever ODX database the CDA has loaded,
not against anything this ECU reports — so matching the fixture's own ID
is the only way to reach RoutineControl through it, rather than this
ECU's own `DoorLockAll`/`WindowCalibrate`, which the fixture doesn't know
about. Neither carries any application logic; see
`diagnostics_config.yaml`'s own comments. A custom ODX fixture describing
this ECU's own real identity would be the cleaner alternative — it isn't
available, for the same reason EDS's own demo documents (the CDA's
PDX-to-MDD converter isn't publicly distributable).

**What this does not prove**: DoIP (the CDA discovers DoIP gateways only
by UDP Vehicle Identification, which EDS has never implemented —
[`EDS#392`](https://github.com/Xaloqi/EDS/issues/392)); the pytest/CAPL
half of EDS's codegen working without a commercial licence (it does not);
or this ECU's own door-ajar/window-stall application logic *through SOVD*
— the CDA's fixture has no route to those at all, so SOVD can't reach
them. See [Phase 2](#phase-2--real-hardware) for how those were verified
instead (raw ISO-TP, this repo's own tooling, no CDA involved).

---

## Phase 4 — DoIP and secure boot

**DoIP, not combined with CAN.** `src/main_doip.c` is a separate,
alternate entry point — `CMakeLists.txt`'s `DIAG_DOIP_ONLY_BUILD` option
selects it *instead of* `src/main.c`, never both in the same image. Xaloqi
EDS ships no example, and no proven architecture, for running CAN and
DoIP concurrently against the same session/security state safely — EDS's
own architecture note designed that ("the diagnostic executor") and
deliberately deferred building it. Attempting that concurrency ourselves,
unproven, would be materially riskier than adding DoIP — see
`src/main_doip.c`'s own header comment.

```bash
# native_sim (loopback only — reachable from inside the process, not the
# host; a disclosed, pre-existing Zephyr/native_sim limitation, not
# something this repo can fix):
west build -b native_sim . -- -DDIAG_DOIP_ONLY_BUILD=ON \
    -DEXTRA_CONF_FILE=boards/native_sim_doip.conf

# real hardware — needs JP6/JP7 ON and a direct Ethernet link to the host
# (see the bill of materials in Phase 2):
west build -b nucleo_h753zi . -- -DDIAG_SKIP_CODEGEN=ON -DDIAG_DOIP_ONLY_BUILD=ON \
    -DEXTRA_CONF_FILE=boards/nucleo_h753zi_doip.conf
west flash
```

**Confirmed**: builds clean on both targets, and boots and runs correctly
on `native_sim` (`UDS stack ready: 7 DIDs 2 DTCs`, DoIP listening on port
13400).

**Not confirmed, disclosed rather than hidden**: on real `nucleo_h753zi`
hardware, this build produces no console output at all — before the
firmware's own first log line, with JP6/JP7 set and a live Ethernet link
to the host. Not a cable or baud-rate artifact (both checked directly).

Diagnosed as far as remote probing over ST-LINK/OpenOCD can honestly take
it, and the findings disagree with each other rather than converging:

- A 25-sample program-counter trace (explicit resume → run 100 ms → halt
  → read PC, repeated) landed on the **exact same address** every time
  across 2.5 real seconds — the signature of a genuine stall, not normal
  idling (the address resolves into Zephyr's own `arch_cpu_idle`, but
  healthy idling still shows *some* PC variation from periodic tick
  interrupts; this showed none).
- Checking whether the system tick timer was even advancing gave a
  **contradictory** result: a register read taken while the core was
  (unintentionally) still halted from the prior test showed it frozen —
  not real evidence, just a confounded test. Redone properly (explicit
  resume, then read), the timer's value had genuinely changed, arguing
  *against* a true stall. A second read in that same sequence then failed
  with `target not halted`, exposing that resume/halt/read sequencing
  over ST-LINK's HLA transport isn't behaving predictably enough here to
  trust further without better tooling.

Rather than force a confident root cause from unreliable signals, this is
left as a genuinely open, honestly-scoped finding: something is wrong on
real hardware, probing attempts so far don't agree on what, and resolving
it needs either a real JTAG session (not ST-LINK's HLA transport) or
physical instrumentation — not more of the same remote register reads.
Tracked as [`#7`](https://github.com/Xaloqi/Zephyr-Reference-ECU/issues/7).

### Secure boot — confirmed working on real hardware

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

**Confirmed, both directions, on real hardware** — not just the happy
path:

- The signed image boots: `*** Booting MCUboot v2.1.0 *** ... Jumping to
  the first image slot ***`, then this ECU's own boot log, ending with
  `[DFU] Image policy registered`. Ordinary UDS/CAN diagnostics
  (`TesterPresent`, same as [Phase 2](#phase-2--real-hardware)) work
  identically underneath — the bootloader is transparent to the running
  application.
- **The authenticity gate is real, not a happy-path illusion**: flashing
  the *unsigned* `zephyr.hex` into the same slot gets a genuine refusal —
  `E: Image in the primary slot is not valid! / E: Unable to find
  bootable image` — and MCUboot loops on its own banner rather than
  jumping anywhere. Verified by actually doing it, then reflashing the
  signed image to confirm it boots clean again.

---

## Licence

This repository's own code: **Apache-2.0** (`LICENSE`). What it depends on
has its own, different licence — see `COMMERCIAL_NOTICE.md` before you
assume anything here is free to regenerate or re-license.
