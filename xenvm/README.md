# xenvm: this ECU as a Xen guest (SoDeV's DomZ), reached over DoIP or CAN

`xenvm/run.sh` builds and boots a three-domain Xen system on a PC, under QEMU.
In DomZ, ReferenceBCM (Xaloqi EDS on Zephyr 4.4.1) answers DoIP from a tester in DomD:

```
QEMU virt (arm64, GICv2, TCG)
└─ Xen 4.22.0
   ├─ Dom0  Linux. Runs only xenstored, and gives the toolstack role to DomD
   ├─ DomD  dom0less, capabilities = <1> (control domain). Linux running xl, xenconsoled,
   │        QEMU 11.1.2 as the device model (-M xenpvh) and the DoIP tester
   └─ DomZ  created by DomD from AGL SoDeV's domz.cfg + two virtio= entries
            (virtio-net, virtio-rng; backend = DomD, grant_usage = 0)
            Zephyr 4.4.1 xenvm + EDS: ReferenceBCM, DoIP on 192.0.2.1:13400
```

The run boots DomZ twice. On each boot the tester in DomD sends routing activation,
TesterPresent, ReadDataByIdentifier F190, an extended session (`10 03`) and two
SecurityAccess seed requests (`27 01`). Every DoIP frame is printed. The last line is
`PASS` or `FAIL: <reasons>` and the exit status matches. A run passes only if all of
those were answered on both boots and the seeds differ between the boots.

## Run it

```sh
git clone https://github.com/Xaloqi/Zephyr-Reference-ECU && cd Zephyr-Reference-ECU
xenvm/run.sh            # build what is missing, boot, check
xenvm/run.sh boot       # boot and check again, reusing the build
xenvm/run.sh clean      # delete xenvm/build
xenvm/run.sh can        # the CAN variant (see below)
```

You need Docker and nothing else: no sudo, no host toolchain, no Zephyr checkout.
Everything is built in a Debian 13 container from the pins in
[`versions.env`](versions.env) and [`west.yml`](west.yml). The build output goes to
`xenvm/build/`, or to `XENVM_BUILD_DIR`. The script is non-interactive and exits non-zero
on failure, so CI can run it as it is.

Measured from a fresh clone with an empty Docker cache for these images (16 cores):
**13 min 17 s** wall-clock (about 4 min of it the builder image), **5.8 GB** in `xenvm/build/` and a **2.8 GB** builder image.
`run.sh boot` takes about **80 s**.

## The CAN variant: `run.sh can`

The same machine, with DomZ on a **CAN bus that DomD owns**, reached through
**virtio-can**. This is SoDeV's CAN architecture (A): a Zephyr guest with a virtio-can
frontend, and a driver domain that owns the controller.

```
QEMU virt (arm64, GICv2, TCG)
└─ Xen 4.22.0
   ├─ Dom0  as above: xenstored only
   ├─ DomD  dom0less, capabilities = <1>. Owns the bus (vcan0) and serves DomZ's devices:
   │        rust-vmm vhost-device-can (on vcan0) and vhost-device-rng, behind Linaro's
   │        xen-vhost-frontend (Xen ioreq server, foreign mapping). ISO-TP tester on vcan0
   └─ DomZ  SoDeV's domz.cfg + virtio-can (device 36) + virtio-rng (backend = DomD,
            grant_usage = 0). Zephyr 4.4.1 xenvm + Xaloqi/zephyr-virtio-can + EDS:
            ReferenceBCM, CAN variant (src/main.c), UDS on 0x7E0/0x7E8
```

```sh
xenvm/run.sh can        # build what is missing (CAN parts included), boot, check
xenvm/run.sh can boot   # boot and check again, reusing the build
```

The run boots DomZ three times. On the first two, the tester in DomD sends
TesterPresent, an extended session (`10 03`), ReadDataByIdentifier F190 (a multi-frame
answer, so EDS waits for the tester's flow control) and two SecurityAccess seed requests,
as UDS over ISO-TP through the kernel's `CAN_ISOTP` socket. A second socket prints every
frame on vcan0. The third boot is a **canary**: vhost-device-can is attached to `vcan9`
while the tester stays on `vcan0`, so nothing may answer. The run passes only if every
request was answered on both boots, the answers crossed vcan0 as `0x7E8` frames, the seed
nonces all differ, and the canary boot stayed silent while EDS was up and the tester's
frames were on the bus ([`scripts/check_can.py`](scripts/check_can.py)).

The CAN parts are built in a second image, `xaloqi-zre-xenvm-can:1`. It is the builder
image plus the Rust toolchain of the `rust` image pinned in [`versions.env`](versions.env),
for DomD's backends. The DoIP image is unchanged. Measured from a fresh clone with
both images removed (16 cores, under another job's load): **13 min 8 s** wall-clock (about 3 min of it the two images), **4.7 GB** in `xenvm/build/`, a
**3.9 GB** CAN image (1.1 GB on top of the builder). A later `run.sh` for DoIP in the same
build directory adds QEMU and the DoIP image (6.3 GB in all). `run.sh can boot` takes about
**90 s**.

### What it took, and where it stands upstream

The Zephyr driver is [Xaloqi/zephyr-virtio-can](https://github.com/Xaloqi/zephyr-virtio-can)
(Apache-2.0), pinned in [`west.yml`](west.yml). It was written from VIRTIO 1.4 and is
unit-tested in its own repository. The backend side is third-party code, pinned by commit
and **patched**: one patch file per repository in [`patches/`](patches/), each naming its
upstream PR or issue.

| Piece | Commit | Patch | Upstream |
|---|---|---|---|
| rust-vmm vhost-device (can, rng) | `c0bfee92` | RX buffers lost until RX stops (PR #924, unchanged) | [#923](https://github.com/rust-vmm/vhost-device/issues/923), [#924](https://github.com/rust-vmm/vhost-device/pull/924) |
| Linaro xen-vhost-frontend | `a1e333c5` | can/rng devices; DriverFeatures read; negotiate on FEATURES_OK; log ioreq errors; one ioreq consumer, kicked from userspace | [#5](https://github.com/vireshk/xen-vhost-frontend/pull/5), [#6](https://github.com/vireshk/xen-vhost-frontend/pull/6), [#7](https://github.com/vireshk/xen-vhost-frontend/pull/7), [#8](https://github.com/vireshk/xen-vhost-frontend/pull/8), [#10](https://github.com/vireshk/xen-vhost-frontend/pull/10) |
| vireshk/vhost (`frontend/stable`) | `abf24853` | can and rng in the device table | [#37](https://github.com/vireshk/vhost/pull/37) |
| mathieupoirier/xen-sys | `8a234c94` | domctl interface 0x18 (Xen 4.22) | [#2](https://github.com/mathieupoirier/xen-sys/pull/2) |

Two more pieces live in DomD:
- [`harness/xs-sock-relay.py`](harness/xs-sock-relay.py). xen-vhost-frontend reaches
  xenstore only through xenstored's Unix socket, which exists only in the domain that
  runs xenstored (Dom0 here). A driver domain has the same protocol on `/dev/xen/xenbus`,
  so the relay serves one from the other
  ([xen-vhost-frontend#9](https://github.com/vireshk/xen-vhost-frontend/issues/9)).
- [`scripts/linux.config`](scripts/linux.config) adds CAN, vcan, ISO-TP, `XEN_VIRTIO`
  and `XEN_PRIVCMD_EVENTFD` (the frontend injects interrupts through privcmd's irqfd) to
  the Dom0/DomD kernel. That kernel is shared with the DoIP variant, which still passes.

## Where DomD's right to map DomZ's memory comes from

DomZ uses `grant_usage=0`. Its virtio drivers hand the device guest-physical addresses,
so the backend has to foreign-map DomZ's RAM (`XENMEM_add_to_physmap_batch`,
`XENMAPSPACE_gmfn_foreign`). Both SoDeV and this harness boot Xen with `xsm=dummy`.
Under that policy the check is `XSM_TARGET`. It passes for the domain
itself, for DomZ's device-model target (stubdomains only) and for a **control domain**
(`is_control_domain()`).

SoDeV makes DomD a control domain with upstream Xen's dom0less property
`capabilities = <0x1>` (`DOMAIN_CAPS_CONTROL`). It is not in their `xen.dtso`.
Their u-boot scripts add it at boot (`fdt set /chosen/domD capabilities <0x1>`,
`meta-xt-rpi5/recipes-bsp/xt-rpi-u-boot-scr/files/boot.cmd.xen.*-dom0.in`), together
with `xen_privcmd.unrestricted=1` on DomD's kernel command line. That flag is needed
because Linux restricts `/dev/xen/privcmd` in any domain that is not the initial one.
This harness does exactly the same ([`scripts/boot.sh`](scripts/boot.sh)). No SoDeV
Xen patch is involved: their `4.22-0007` (`xsm_map_gmfn_foreign`) covers the opposite
direction, a device model sharing its own memory into a guest, for Venus blobs.

Removing `capabilities` from DomD makes it fail exactly as SoDeV's boot-script comment
records for their board: `libxl_cpu_bitmap_alloc: failed to retrieve the maximum number
of cpus`, `getting physinfo: Operation not permitted`, and no DomZ.

## Versions: upstream or SoDeV-patched

| Piece | Here | SoDeV's board (sodev-demo-workspace-rpi @ dc2755f6) |
|---|---|---|
| Xen | **4.22.0 `d45d5687f1`, unpatched**. arm64 defconfig (XSM with FLASK and SILO compiled in) + `EXPERT` + `IOREQ_SERVER`, booted with `xsm=dummy` | Same SHA + ~33 patches; FLASK compiled, booted with `xsm=dummy` |
| DomD privilege | upstream dom0less `capabilities = <0x1>`, `xen,enhanced` | the same property, set by u-boot |
| Dom0 | Linux 6.18.57, upstream C xenstored `--priv-domid 1`, nothing else | Zephyr Dom0 with zephyr-xenlib's xenstore server, patched to treat DomD as toolstack (0006/0007) (default flavour) |
| Introducing DomD to xenstore | [`harness/xs-seed-port.c`](harness/xs-seed-port.c) (Dom0, 40 lines, see its header) | zephyr-xenlib enumerates dom0less domains itself |
| DomD | Linux 6.18.57 (kernel.org), Debian 13 userspace, Xen 4.22.0 tools (unpatched) | Yocto Linux, xen-tools + their libxl patches |
| Device model | QEMU 11.1.2, unpatched, started by hand after `xl create -p` | QEMU 10.0.2 + patches, spawned by `xl devd` (their libxl 0014/0015 `backend_type=qemu`) |
| Transport | virtio-mmio (upstream xl offers only mmio) | DomA uses virtio-pci (their patches 0011/0018/0020) |
| Console | xenconsoled in DomD, `/tool/xenconsoled/domid = 1` | the same, plus a console seeder their Zephyr xenstore needs |
| DomZ | SoDeV's `domz.cfg` ([`harness/domz.cfg`](harness/domz.cfg), only the kernel path changed) + `virtio=` | `virtio = []`, no device model |
| Zephyr | **v4.4.1 `1f6485ec`**, SDK 1.0.1, board `xenvm` (GICv2) | the same SHA |
| EDS | **v1.23.0** `bd5d008` | not present |
| Machine | QEMU 10.0 `virt`, cortex-a57, 4 CPUs, 4 GiB, TCG | Raspberry Pi 5 / 4 (Cortex-A76 / A72, GIC-400) |

## Honest gaps

- **Stack sizes are measured, not proven.** [ZRE#34](https://github.com/Xaloqi/Zephyr-Reference-ECU/issues/34) was a real overflow of Zephyr's default network stacks on arm64, fixed in [`boards/xenvm_doip.conf`](../boards/xenvm_doip.conf) at about twice the peak measured under host load. That is a margin from observation, not a worst-case stack analysis.
- **No grant isolation.** Zephyr has no grant-DMA (Xen virtio-grant) support, so
  DomZ runs with `grant_usage=0`. The backend domain can read and write all of DomZ's
  RAM, and DomD is a control domain that could do far more besides. `grant_usage=1`
  would change only what libxl advertises; Zephyr would ignore it.
- **Entropy is DomD's to give.** SecurityAccess seeds come from virtio-rng, whose bytes come
  from QEMU in DomD (`/dev/urandom` there). DomZ trusts its backend domain for entropy, and that
  domain has full access to it anyway (see above).
- **No stack canaries.** `CONFIG_STACK_CANARIES=n` and `CONFIG_EDS_REQUIRE_STACK_CANARIES=n`.
  virtio-rng is a `POST_KERNEL` driver with no ISR API, so Zephyr would seed the canary from
  an LCG over the cycle counter, which only looks like a canary. See
  [`boards/xenvm_doip.conf`](../boards/xenvm_doip.conf).
- **No watchdog.** `CONFIG_WATCHDOG=n`, EDS's degraded mode, logged at every boot. Zephyr v4.4.1
  has no Xen watchdog driver (`drivers/watchdog/wdt_xen.c` exists only in Zephyr main).
- **Placeholder keys.** The SecurityAccess keys are EDS's public placeholders, and EDS
  says so at boot. A seed can be requested, and anyone can compute the key.
- **picolibc, not newlib.** SDK 1.0.1 has no newlib; the conf says so explicitly
  (`CONFIG_EDS_REQUIRE_NEWLIB=n`).
- **NVM is RAM.** A simulated flash in DomZ's RAM. It survives ECUReset, not `xl destroy`.
- **Emulated, not measured on a board.** Timing under TCG says nothing about a Pi 5.
- **Not pinned:** Debian 13 packages (builder image and rootfs) follow the
  current point release; Zephyr's Python requirements resolve to the newest compatible
  versions. Everything that is compiled into Xen, the kernels, QEMU or DomZ is pinned by
  SHA or SHA-256.
- `xl destroy` reports `unable to remove device` for the virtio devices. Nothing in DomD runs
  the backend half of the device teardown handshake (on SoDeV that is `xl devd`). DomZ is destroyed anyway.

### CAN variant: honest gaps

- **Patched third-party backends.** Until the four patches above are merged upstream,
  this needs our patch files. Two of the fixes matter under load. Without vhost-device
  #924, EDS stopped answering on about 1 boot in 15. Without the single-ioreq-consumer
  change, Xen saw ioreqs completed twice and aborted DomZ's MMIO. See
  [the stress result](#can-variant-under-host-load).
- **No grant isolation**, as for DoIP: `grant_usage=0`, and DomD foreign-maps DomZ's RAM.
- **A virtual bus on a PC.** DomD's bus is `vcan0` in QEMU under TCG, with no CAN
  controller, no bit timing and no real bus load. Bit timing belongs to the device side:
  the driver accepts and ignores `can_set_bitrate()`.
- **Classic CAN only.** CAN FD and RTR are unit-tested in the driver repository, not run
  end-to-end here.
- **Backend behaviour we did not fix:** vhost-device-can loops the guest's own frames
  back to it ([#925](https://github.com/rust-vmm/vhost-device/issues/925), fix PR #937
  open; EDS's filters never match its own 0x7E8). Its reader busy-polls and keeps one DomD
  vCPU busy ([#1009](https://github.com/rust-vmm/vhost-device/issues/1009)). It writes a
  full 64-byte sdu into every RX buffer, so the driver posts 64-byte buffers
  ([#1008](https://github.com/rust-vmm/vhost-device/issues/1008)).
- **No kernel fast path for notifications.** Every queue notify is an ioreq to the
  frontend in userspace. That is slower than privcmd's ioeventfd, and it is the price of
  the fix above. Irrelevant at CAN rates; not measured.
- **SoDeV's own stack spawns QEMU** as DomZ's device model (`xl devd`, `backend_type=qemu`).
  QEMU on Xen cannot serve a vhost-user backend (it has no file descriptor for guest RAM),
  so their board would need xen-vhost-frontend or an equivalent in DomD. That is a design
  point for SoDeV, not a defect here.
- The DoIP gaps apply too: entropy from DomD, no stack canaries, no watchdog, placeholder keys.

### CAN variant under host load

The unpatched backends stalled under host load: EDS stopped answering, mostly after a
multi-frame exchange. Load recipe from ZRE#34: 16 busy loops on the 16-thread host, three runs
in parallel (load average 20 to 40), 15 UDS requests per boot.

| Backends | Boots | Stalled | Cause |
|---|---|---|---|
| As in the spike (three patches) | 99 | **7** | 6 × RX buffers lost (vhost-device #923); 1 × ioreq completed twice (Xen: `bad IO state 3`, data abort in DomZ) |
| With the four patches in `patches/` | 96 | **0** | |

At the unpatched rate (7 in 99), 0 in 96 has a probability of about 9×10⁻⁴. `run.sh can`
itself, under the same load: 9 runs with `XENVM_CAN_BOOTS=8`, all PASS (72 answered boots,
9 silent canaries). These are measurements on one host, not a proof that no race is left.

## Going further

This demo, and everything it runs, is free. Each natural next step crosses a licence
boundary. The boundaries are the ones in the main README's
[Tiers table](../README.md#tiers--what-is-free-and-what-is-not) and in
[`COMMERCIAL_NOTICE.md`](../COMMERCIAL_NOTICE.md); they are not repeated here.
Prices are on the product pages.

| You want to... | You need |
|---|---|
| Change a DID, DTC or routine and regenerate the C | An EDS commercial licence (the codegen templates). See [EDS](https://xaloqi.com/eds). |
| Run full TestLab campaigns over DoIP against DomZ | TestLab Pro (`xaloqi-tester-pro`). See [TestLab](https://xaloqi.com/testlab). The stdlib probe in this directory ([`harness/doip_probe.py`](harness/doip_probe.py)) is the free substitute: it checks the handful of exchanges above, not a campaign. |
| Ship DomZ firmware closed-source | An EDS commercial licence. EDS is GPL-2.0 otherwise. |
| Safety evidence for an ASIL domain | EDS Professional ships ISO 26262 work products for EDS. See [Safety](https://xaloqi.com/safety). |

**This xenvm configuration is not a safety configuration.** The work products cover
EDS; they do not make this build qualified or certified, and nothing here claims that.
See [Honest gaps](#honest-gaps): no grant isolation, entropy from DomD, no stack
canaries, no watchdog, placeholder keys.

## Files

| File | What it is |
|---|---|
| `run.sh` | Entry point on the host |
| `versions.env`, `west.yml` | Every pin |
| `docker/Dockerfile` | The builder image |
| `scripts/build.sh` | In the container: Xen, Xen tools, Linux, QEMU DM, rootfs, helper, Zephyr image |
| `scripts/boot.sh` | In the container: host DTB with dom0less DomD, initramfs, QEMU |
| `scripts/check.py` | Reads the serial log, prints the evidence, PASS/FAIL |
| `harness/dom0-init.sh`, `harness/domd-init.sh`, `harness/domd-test.sh` | What Dom0 and DomD run |
| `harness/doip_probe.py` | The DoIP tester (Python standard library only) |
| `harness/domd-test-can.sh` | What DomD runs for `run.sh can` (backends, three DomZ boots, the canary) |
| `harness/isotp_probe.py`, `harness/can_dump.py` | The UDS-over-ISO-TP tester and the wire capture (Python standard library only) |
| `harness/xs-sock-relay.py` | xenstore socket in DomD for xen-vhost-frontend (see above) |
| `docker/Dockerfile.can`, `scripts/build-can.sh`, `scripts/check_can.py`, `patches/` | The CAN variant's image, build, check and backend patches |
| `../boards/xenvm_doip.conf`, `../boards/xenvm_doip.overlay` | The Zephyr side: Kconfig, virtio slots, simulated flash |
| `../boards/xenvm_can.conf`, `../boards/xenvm_can.overlay` | The same for the CAN variant |

The tester is a stdlib-only probe, not TestLab, because the public `xaloqi-tester`
package has no DoIP transport (DoIP is part of TestLab Pro).

## Output (abridged)

```
[run] wall-clock 13 min 16 s; build dir 5.8G; full log xenvm/build/serial.log
========================================================================
Evidence from DomD (domid 1, dom0less, capabilities = <1>)
  xen_version            : 4.22.0
  Name                                        ID   Mem VCPUs	State	Time(s)
  Domain-0                                     0   512     1     r-----       3.6
  DomD                                         1  1024     2     r-----       4.0
------------------------------------------------------------------------
DomZ boot 1
  DomZ domid=2
  /local/domain/1/backend/virtio/2/0/type = "virtio,device1"
  /local/domain/1/backend/virtio/2/0/transport = "mmio"
  /local/domain/1/backend/virtio/2/0/grant_usage = "0"
  ...
  --- QEMU device model in DomD: pid 107, qemu-dm
  DOIP TX 02 fd 00 05 00 00 00 07 0e 00 00 00 00 00 00
  DOIP RX 02 fd 00 06 00 00 00 09 0e 00 e4 00 10 00 00 00 00
  ROUTING ACTIVATION code 0x10
  UDS 3e 00 -> 7e 00
  UDS 22 f1 90 -> 62 f1 90 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
  UDS 10 03 -> 50 03 00 19 01 f4
  UDS 27 01 -> 67 01 00 f5 9b c3 55 91 00 01
  UDS 27 01 -> 67 01 ea 4d 91 29 e3 9c 00 02
  <wrn> reference_bcm_doip: [SEC] Using placeholder AES keys — inject OEM keys before production
  <inf> reference_bcm_doip: [SEC] SecurityAccess seeds from entropy device virtio-rng
  <wrn> zephyr_wdt: WDT: No watchdog device available — running without HW supervision.
------------------------------------------------------------------------
DomZ boot 2
  ...
seeds boot 1: 00 f5 9b c3 55 91 00 01 | ea 4d 91 29 e3 9c 00 02
seeds boot 2: 15 0e bc a8 14 64 00 01 | 9b 8a 39 3a 0d 11 00 02
========================================================================
PASS: DomD (dom0less, DOMAIN_CAPS_CONTROL) created DomZ and served its virtio-net/rng with QEMU; ...
```

The real log prints every DoIP frame, including each `0x8002` ACK. A seed is 8 bytes:
6 bytes from the RNG callback, then a 2-byte counter that restarts at every boot
(`00 01`, `00 02`). The check compares the 6-byte part across boots. The VIN
reads as zeros because `diagnostics_config.yaml` gives F190 no value; its length (17)
is right.

The check has been run against two known-bad builds. Without the TRNG callback
(`DIAG_ENTROPY_SEEDS=OFF`, EDS's LFSR fallback), both boots hand out
`70 e2 38 71 9c 38 …` and the run FAILs. With prj.conf's
`CONFIG_STACK_CANARIES=y` left in, the build stops on its `.config` assertion.
