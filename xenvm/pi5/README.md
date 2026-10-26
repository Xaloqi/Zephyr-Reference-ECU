# xenvm/pi5: virtio-can on a real Raspberry Pi 5 (SoDeV CAN architecture A)

**State: prepared, not yet run on hardware.** Everything here builds and is rehearsed
under QEMU. Nothing has touched a Pi 5 yet.

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
