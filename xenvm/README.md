# xenvm: this ECU as a Xen guest (SoDeV's DomZ), reached over DoIP

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
```

You need Docker and nothing else: no sudo, no host toolchain, no Zephyr checkout.
Everything is built in a Debian 13 container from the pins in
[`versions.env`](versions.env) and [`west.yml`](west.yml). The build output goes to
`xenvm/build/`, or to `XENVM_BUILD_DIR`. The script is non-interactive and exits non-zero
on failure, so CI can run it as it is.

Measured from a fresh clone with an empty Docker cache for these images (16 cores):
**13 min 17 s** wall-clock (about 4 min of it the builder image), **5.8 GB** in `xenvm/build/` and a **2.8 GB** builder image.
`run.sh boot` takes about **80 s**.

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
| EDS | `4befaac` (main, with EDS#499/#500/#502) | not present |
| Machine | QEMU 10.0 `virt`, cortex-a57, 4 CPUs, 4 GiB, TCG | Raspberry Pi 5 / 4 (Cortex-A76 / A72, GIC-400) |

## Honest gaps

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
| `../boards/xenvm_doip.conf`, `../boards/xenvm_doip.overlay` | The Zephyr side: Kconfig, virtio slots, simulated flash |

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
