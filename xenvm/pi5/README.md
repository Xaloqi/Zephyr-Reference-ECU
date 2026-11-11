# xenvm/pi5: virtio-can on a real Raspberry Pi 5 (SoDeV CAN architecture A)

**State: run on hardware, 2026-11-09** (classic CAN and CAN FD, one Pi 5, SoDeV image
`dc2755f6`). Every functional step passes; see [Results](#results-2026-11-09) for the
timing, the bench notes, the known issues and what was not measured.

The Pi 5 version of [`run.sh can`](../README.md#the-can-variant-runsh-can). It starts
from AGL SoDeV's own Pi 5 image
([sodev-demo-workspace-rpi](https://github.com/automotive-grade-linux/sodev-demo-workspace-rpi),
`./build.sh -z`) and adds:

```
Raspberry Pi 5 (8 GB) + Waveshare 2-CH CAN HAT (2 x MCP2515 on RP1 SPI0, 16 MHz)
└─ Xen 4.22 (SoDeV)
   ├─ Dom0  Zephyr, xenstore server (SoDeV)
   ├─ DomD  Linux, the toolstack (SoDeV). Owns the HAT: can0 and can1 (this layer).
   │        rust-vmm vhost-device-can on can0 + vhost-device-rng, behind
   │        xen-vhost-frontend (this layer, patched as in ../patches/)
   ├─ DomZ      SoDeV's stock Zephyr DomZ, untouched
   └─ DomZ-CAN  ReferenceBCM (EDS) on Zephyr 4.4.1 + Xaloqi/zephyr-virtio-can,
                ISO 15765-4 ECU 1: request 0x7E1, response 0x7E9
                                            │ can0
   physical bus, 500 kbit/s ════════════════╪═══════════ can1 (tester, DomD)
                                            │
   NUCLEO-H753ZI + SN65HVD230: ReferenceBCM, ECU 0: 0x7E0 / 0x7E8 (../../README.md)
```

The tester in DomD uses the HAT's second channel (`can1`), so every request to either
ECU crosses the wire. A tester on `can0` would reach DomZ-CAN through SocketCAN's local
loopback without ever touching the bus.

## What is here

| Path | What it is |
|---|---|
| `meta-xaloqi-virtio-can/` | Yocto layer for SoDeV's DomD build (wrynose): recipes for vhost-device (can, rng) and xen-vhost-frontend, the CAN HAT in DomD's partial device tree, the kernel options, and the DomZ-CAN package |
| `sodev-add.sh` | Copies the layer into a SoDeV workspace (with `../patches/` and the DomZ-CAN image) and adds it to the DomD component of `rpi5-sodev.yaml` |
| `rehearse.sh`, `rehearse/` | Runs the bench driver end to end under QEMU, before the board exists |
| `bench/` | Host and DomD tools for the bench sessions: `xaloqi-domd-load` (the DomD load for P2 cells C/D: start, check, stop, `cell`), `xaloqi-b3-group` (a group of loaded cells from a fresh boot), `xaloqi-proc-cpu` (CPU time of a process over a window), `xaloqi-teardown-loop` (N create/destroy cycles of DomZ-CAN and what each leaves behind), `console-send.py` (a file to DomD over the Xen console as base64 with a sha256 check) |
| `rehearse-b3.sh`, `rehearse/domd-load-rehearse.sh`, `rehearse/domd-teardown.sh` | DomD scripts for the same QEMU harness: the load tool end to end with P2 (`rehearse-b3.sh <build> load`), and a create/destroy loop of DomZ-CAN that records xen-vhost-frontend's output and Xen's view of the domain (`rehearse-b3.sh <build> teardown`) |
| `rehearse-b3.sh <build> b4\|reset\|idle`, `rehearse/domd-b4-rehearse.sh`, `rehearse/domd-reset-proof.sh`, `rehearse/domd-idle-compare.sh` | The B4 rehearsals under QEMU: every bench cell with the baked-in tools (placement printed, the pin check stopped on purpose), N paused-then-destroyed DomZ-CAN cases for the `reset()` fix, and vhost-device-can's idle CPU before and after the reader-poll patch |
| `scripts/gen-crates-inc.py` | Regenerates the recipes' crate lists from a (patched) `Cargo.lock` |

In the SD image, DomD gets `xaloqi-can-bench`, one subcommand per bench step
(`up`, `wire`, `nucleo`, `domz`, `canary`, `p2`, `down`). Each step ends in `PASS` or
`FAIL: <reason>`.

## Build the SD image

You need Docker. The SoDeV build is theirs; this adds one layer to its DomD.

```sh
# 1. DomZ-CAN, as ECU 1 (the same build as run.sh can, with other CAN IDs)
XENVM_BUILD_DIR=$PWD/xenvm/build-ecu1 XENVM_CAN_ECU_INDEX=1 xenvm/run.sh can   # must PASS
# 2. SoDeV's workspace, plus this layer
git clone https://github.com/automotive-grade-linux/sodev-demo-workspace-rpi sodev
git -C sodev checkout dc2755f603feb6166b489e2c3cc18eedf8e8f279
xenvm/pi5/sodev-add.sh sodev xenvm/build-ecu1
(cd sodev && ./build.sh -z --ram=8g)
```

`sodev-add.sh` refuses a DomZ image that was not built as ECU 1, or that is stale
against these sources.

What goes into the image, so that nothing is sent to DomD and patched live on the Pi:

- `xaloqi-can-bench`, `xaloqi-domd-load`, `xaloqi-b3-group`, `xaloqi-proc-cpu` and `xaloqi-teardown-loop` in `/usr/bin`, the relay
  (`/usr/libexec/xaloqi-can/xs-sock-relay.py`, with the fd fix of #64), and `/usr/share/xaloqi-can/zre.rev`,
  the commit the layer was copied from (`dirty=0` if the tree was clean).
- The backends, from `xenvm/patches/`, applied in this order per repository:
  - vhost-device: `vhost-device-c0bfee92.patch` (#924), then `vhost-device-c0bfee92-reader-poll.patch` (the
    reader change of #1020, backported onto this pin: the reader no longer busy-polls a vCPU; drop on pin bump)
  - vireshk/vhost: `vireshk-vhost-abf24853.patch`, then `vireshk-vhost-abf24853-reset.patch` (`reset()` returns the
    interrupt of a never-activated device instead of panicking)
  - xen-sys: `xen-sys-8a234c94.patch`
  - xen-vhost-frontend: `xen-vhost-frontend-a1e333c5.patch`, then `xen-vhost-frontend-a1e333c5-teardown.patch`
    (the ioreq range is released even if a reset or shutdown panics; a poisoned lock is taken back)
- EDS v1.28.0 in DomZ-CAN (pinned in `west.yml` and `versions.env`).

In DomD, `cat /usr/share/xaloqi-can/zre.rev`, `xl vcpu-list` and the PASS line of `xaloqi-can-bench domz` (it ends
with the pCPU the guest got) say what the image is and where DomZ-CAN runs. To rehearse every bench cell before the
board: `xenvm/pi5/rehearse-b3.sh <build> b4` (needs `XENVM_DOMD_WAIT=2400`).

### CAN FD: the Waveshare 2-CH CAN FD HAT

The same steps with the FD HAT (Rev2.1: 2 x MCP2518FD, 40 MHz, CAN_0 on RP1 SPI0
CE0 + INT GPIO25, CAN_1 on RP1 SPI1 CE0 = GPIO18 + INT GPIO24, its default "Dual
SPI Mode"), and a CAN FD DomZ-CAN:

```sh
XENVM_BUILD_DIR=$PWD/xenvm/build-ecu1-fd XENVM_CAN_ECU_INDEX=1 XENVM_CAN_FD=1 xenvm/run.sh can
XAQ_CAN_HAT=mcp2518fd xenvm/pi5/sodev-add.sh sodev xenvm/build-ecu1-fd
(cd sodev && ./build.sh -z --ram=8g)
```

`XAQ_CAN_HAT` picks the DomD device tree (`domd-mcp2518fd-can.dtsi` instead of
`domd-mcp2515-can.dtsi`); the kernel has both drivers built in. `sodev-add.sh`
refuses a classic DomZ-CAN for the FD HAT and the other way round. In DomD,
`xaloqi-can-bench up` sees the mcp251xfd driver and brings both channels up at
500 kbit/s (87.5 %) with a 2 Mbit/s data phase (80 %; `XAQ_DBITRATE`), and
`burst` / `p2load` measure ISO-TP burst traffic on it. One HAT at a time: both
use RP1 SPI0 CE0 and GPIO25.

EDS side: from v1.27.0 an FD-mode EDS sends every frame (SF, FF, CF, FC) as a CAN FD
frame (EDS#557), which a Linux CAN FD ISO-TP socket accepts; BRS is not set by this
ECU (see `src/main.c`). Before v1.26.0 the ECU went mute after an unanswered classic
FF (EDS#541); both bench ECUs now pin v1.28.0.

## Results (2026-11-09)

One bench session: classic CAN (2-CH isolated CAN HAT, 2 x MCP2515, 16 MHz) in the morning,
CAN FD (2-CH CAN FD HAT, 2 x MCP2518FD, 40 MHz) in the afternoon. SoDeV `dc2755f6`
(`./build.sh -z --ram=8g`), EDS v1.27.0, Zephyr 4.4.1, zephyr-virtio-can v0.2.0. The NUCLEO
(ECU 0) is this repo's default build. A CANable in listen-only mode confirmed every step from
outside the Pi.

**Functional: every step passes, classic and FD.** Xen 4.22 boot, both HAT channels up in
DomD (500 kbit/s, 87.5 %; FD data phase 2 Mbit/s, 80 %), wire self-test, UDS to the NUCLEO,
UDS to EDS in the Zephyr DomZ-CAN across the physical bus (ECU 1), and the canary (backend on
a virtual bus: DomZ-CAN silent, NUCLEO answering, 0 frames on 0x7E9). On FD every ISO-TP frame of
every DomZ-CAN answer is an FD frame, including a 628-byte one.

**CAN FD burst: 0 of 32,000 frames lost** (500 back-to-back ISO-TP messages of 4,000 bytes
between the HAT's two channels, BS 0 / STmin 0; no bus errors, no rx overruns). Against
DomZ-CAN, 200 requests that each return 628 bytes: none lost, no response frame missing.

**P2** (TesterPresent, 1,000 requests per run, 20 ms apart, a fresh DomZ-CAN boot per run,
DomD idle; measured at the tester's controller, own echo to answer, one kernel clock). The
ReferenceBCM's P2 is 25 ms; ISO 14229's typical 50 ms was never exceeded (largest value
46.0 ms). All 12,000 classic and 6,000 FD requests were answered.

| Classic CAN | Runs | Median | p99 | Max |
|---|---|---|---|---|
| NUCLEO, bare metal | 6 | 0.28-0.35 ms | 1.2 ms | 1.3 ms (two runs: 7.0 and 2.4 ms) |
| DomZ-CAN, pCPU 0 (SoDeV's `domz.cfg`) | 3 | 1.7-4.5 ms | 11.5-14.2 ms | 21.0-21.4 ms |
| DomZ-CAN, pCPU 3 | 3 | 0.47-1.27 ms | 3.9-4.9 ms | 5.9-8.1 ms |

An earlier set of three pCPU 0 runs, before the tool fix below, had a max of 46.0 / 23.5 /
24.2 ms.

| CAN FD (2 Mbit/s data) | Runs | Median | p99 | Max |
|---|---|---|---|---|
| DomZ-CAN, pCPU 0 | 3 | 0.98-3.15 ms | 13.4-18.0 ms | 19.7-32.3 ms (two runs over 25 ms) |
| DomZ-CAN, pCPU 3 | 3 | 1.52 ms | 4.3-4.6 ms | 8.2-20.5 ms |

The NUCLEO's two outliers fell in runs where the tool had to use the send time instead of the
echo, which overstates P2, so part of them may be the tool's. On both classic and FD, where
DomZ-CAN runs matters more than the virtio-can path: on pCPU 0 it shares a core with Dom0
and DomD's vCPU 0, and its tail is about three times longer than on a core of its own.

### Results, DomD under load (2026-11-11)

Two busy loops (one per DomD vCPU) and `candump -L can0 can1` (`bench/xaloqi-domd-load`), P2 as above,
a fresh DomZ-CAN per run, **with vhost-device-can's busy-poll present** (unpatched images). Values in ms.

| Cell | Runs | Median | p95 | p99 | Max |
|---|---|---|---|---|---|
| NUCLEO, DomD idle (classic) | 1 | 0.388 | 0.403 | 0.412 | 1.091 |
| NUCLEO, DomD loaded (classic) | 5 | 0.32 to 0.39 | 0.81 to 1.09 | 1.15 to 1.22 | 1.24 to 1.31 |
| DomZ-CAN on pCPU 0, DomD loaded (classic, 5 runs: 2 asked for pCPU 0, 3 asked for pCPU 3 and ignored) | 5 | 18.3 to 19.4 | 29.5 to 37.1 | 45.4 to 49.4 | 49.8 to 67.4 |
| DomZ-CAN pCPU 3, DomD idle (FD) | 1 | 1.515 | 1.941 | 4.121 | 7.924 |
| DomZ-CAN pCPU 3, DomD loaded (FD) | 3 | 3.5 / 3.3 / 3.5 | 11.5 / 11.3 / 11.5 | 15.5 / 12.8 / 14.9 | 19.5 / 17.3 / 16.9 |
| DomZ-CAN pCPU 0, DomD loaded (FD) | 2 | 19.5 / 19.5 | 30.7 / 29.6 | 49.5 / 49.0 | 60.0 / 63.5 |

A loaded DomD leaves the NUCLEO alone. DomZ-CAN on pCPU 0, the core it shares with DomD's vCPU 0 (running a busy loop),
goes from 1.7 to 4.5 ms median idle on the classic image (1.0 to 3.2 ms on FD; 11-09, above) to about 19 ms median and 50 to 67 ms max loaded, on both images. On its own core (FD, pCPU 3) it
holds 3.5 ms median and under 20 ms max, so placement matters under load as it did idle. The classic image's bench
tool predates `XAQ_DOMZ_CPUS`, so its cells asked for pCPU 3 ran on pCPU 0 (hard affinity `0 / all` in
`xl vcpu-list`); there is no classic pCPU 3 loaded result. The tool now prints the guest's pCPU in each run, and
`xaloqi-domd-load cell` stops if it is not the one asked for. The classic tool is also the pre-fix one, so the 2 to 3
NUCLEO timeouts in the classic runs are probably its old timeout counting. Per-run numbers on request; the
EDS#562 download numbers are in that issue.

### Pinning DomZ-CAN

`XAQ_DOMZ_CPUS` replaces the `cpus =` line of SoDeV's `domz.cfg` in the config
`xaloqi-can-bench` builds for DomZ-CAN. Set it in DomD on the step that starts DomZ-CAN:

```sh
XAQ_DOMZ_CPUS=3 xaloqi-can-bench domz     # pCPU 3; unset keeps domz.cfg's "0"
xaloqi-can-bench p2 1                     # ECU 1 = DomZ-CAN
```

pCPU 3 was free because this image has no Android domain; with one, pick a core nobody
else uses.

### Bench notes

- The backend is `backend=1`: in SoDeV's image DomD is `Dom0less-1` in xenstore, so
  `backend=DomD` does not resolve.
- Flash the NUCLEO with openocd connect-under-reset, or it fails with "examination failed /
  Unable to reset target":
  `openocd -f interface/stlink.cfg -c "reset_config srst_only srst_nogate connect_assert_srst" -f target/stm32h7x.cfg -c "program zephyr.hex verify reset exit"`.
- On the mcp251x driver a fast ECU's answer can arrive before the echo of the tester's own
  request. `xaloqi-can-bench p2` waits for the echo and, if it comes after the answer, uses the
  send time (`echo_late` in its output).
- Bus ground is the isolated HAT's **G** to the transceiver's GND, not the Pi's.

### Known issues

- A destroyed DomZ-CAN domain stays "dying" (one per create/destroy cycle from a boot's second create).
  Killing the stale `xl create -p` or `xen-vhost-frontend` does not free it (it does under QEMU).
  xen-vhost-frontend's threads panic at every create (`src/main.rs:85:56`, `XBInvalidState`) and the
  guest still works; a later create can fail (`PoisonError` in the frontend; twice, on the FD image's
  pCPU 0 runs, while three creates in a row also worked elsewhere). So run one group of loaded cells per
  boot (`bench/xaloqi-b3-group`).
- `xs-sock-relay.py` leaks a xenbus fd per client and dies at 1,024 fds, after which every `xl create`
  fails ([#63](https://github.com/Xaloqi/Zephyr-Reference-ECU/issues/63)).
- DomD's `flat L2 bridge activation` unit fails at boot (SoDeV's networking). It does not
  affect CAN.
- vhost-device-can's reader busy-polls a DomD vCPU while a backend runs
  ([rust-vmm/vhost-device#1009](https://github.com/rust-vmm/vhost-device/issues/1009)).
- VIRTIO 1.4 has no bit for bitrate switching, so DomZ-CAN's FD frames go out without BRS
  (the tester's frames have it).

### Not measured

An Android domain, the NUCLEO on CAN FD (its SN65HVD230 is a classic
transceiver), and the polling path. DomD under load is measured above, only with the busy-poll present. P2 under burst load (`p2load`) needs the NUCLEO on FD.

## Rehearse it without the board

```sh
xenvm/pi5/rehearse.sh xenvm/build-ecu1
```

This boots the QEMU harness of `run.sh can` and runs, in its DomD, the same
`xaloqi-can-bench` that ships in the SD image: `up`, `nucleo`, `domz`, `p2` for both ECUs,
`canary` and `down`. Three things are virtual, and only here:
- `can0` and `can1` are vcan devices joined into one bus.
- The NUCLEO is a stand-in that is not EDS. Its seeds spell `FAKE`.
- xl is upstream, which has no `backend_type` key.

Its timing is TCG on a PC. It shows that the measurement runs, not what a Pi 5 measures.

## Differences from SoDeV's image, and why

- **DomD owns the HAT.** No Xen change is needed for that. SoDeV already maps all of
  RP1's peripheral window into DomD (its pcie2 `xen,reg` aperture), and SPI0 and the
  GPIO bank are inside it. The layer adds SPI0, the two MCP2515s and their pins to DomD's
  partial device tree. It does not use the `DOMD_CAN_TYPE` / `domd_can` overlay path:
  SoDeV's Pi 5 flow does not apply that overlay to DomD's device tree.
- **`backend_type=standalone`** on DomZ-CAN's `virtio=` entries. SoDeV's libxl (their
  patch 0014) defaults virtio backends to QEMU and would spawn one. Upstream xl has no
  such key, which is why `run.sh can`'s config does not have it.
- **The xenstore relay** ([`../harness/xs-sock-relay.py`](../harness/xs-sock-relay.py))
  runs in DomD, as in `run.sh can`, because SoDeV's xenstore server is in the Zephyr
  Dom0.
- DomD's `capabilities = <1>` and `xen_privcmd.unrestricted=1` come from SoDeV's u-boot
  script and are unchanged ([`../README.md`](../README.md#where-domds-right-to-map-domzs-memory-comes-from)).

## Not here

The other architecture SoDeV is evaluating, DomZ owning the CAN controller by passthrough,
is theirs. It is not part of this directory.
