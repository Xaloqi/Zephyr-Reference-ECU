# xenvm/can-spike: virtio-can frontend spike (not merged)

> **Superseded by `xenvm/run.sh can` ([ZRE#37](https://github.com/Xaloqi/Zephyr-Reference-ECU/pull/37)).**
> This branch is kept as the spike's record (Q1 Linux 7.2 guest, option a, the driver self-test).
> It stalls under host load: vhost-device-can loses RX buffers (rust-vmm/vhost-device#923), and
> the frontend shares ioreqs with privcmd's ioeventfd. Both are fixed only in `run.sh can`.

**Spike branch, not a product.** This directory answers one question for AGL SoDeV's CAN
architecture (A): can a Zephyr DomU (DomZ) reach a CAN bus that a driver domain (DomD) owns,
through virtio-can, using upstream pieces? EDS, running in DomZ, answers UDS over ISO-TP from
a tester in DomD.

```
QEMU virt (arm64, TCG)
└─ Xen 4.22.0
   ├─ Dom0   xenstored only
   ├─ DomD   dom0less, capabilities=<1>
   │         vcan0 ── vhost-device-can ─┐  (rust-vmm, vhost-user)
   │                  vhost-device-rng ─┤
   │                  xen-vhost-frontend ┘  (Linaro; IOREQ server + foreign mapping)
   │         tester: Python stdlib, kernel CAN_ISOTP socket on vcan0
   └─ DomZ   Zephyr v4.4.1 xenvm + can_virtio driver (out-of-tree module) + EDS
             virtio-mmio slot 0 = virtio-can (device 36), slot 1 = virtio-rng; grant_usage=0
```

## Run

```sh
xenvm/run.sh                                     # base harness, from this branch
xenvm/can-spike/run-spike.sh all                 # build, then Q1, Q2, Q3; each prints PASS/FAIL
```

You can also run the stages one at a time:

| Stage | What it does |
|---|---|
| `build` | Clones the backends at the commits in `versions.env`, applies `patches/`, and cross-builds them for arm64 in `$RUST_IMAGE`. Builds Linux 7.2.12 (the reference guest) and two Zephyr images: the driver test app and ReferenceBCM CAN |
| `q1` | Backend wiring, proved with Linux's own driver: a Linux 7.2.12 DomU exchanges frames with DomD's vcan0 in both directions |
| `qa` | Option (a): vhost-device-can behind QEMU's `vhost-user-test-device` on the xenpvh device model. **Expected to fail**; the campaign record explains why |
| `q2` | `test-app/` exercises the driver against the real backend: filters, TX/RX, start/stop, error codes |
| `q3` | ReferenceBCM (EDS) in DomZ. The tester sends 3E 00, 10 03, 22 F190 (multi-frame) and 27 01 ×2. Two boots must give different seeds. The third boot is a canary: the backend sits on another vcan, so the tester must get nothing |
| `q3-stress` | 5 boots × 3 rounds, plus the canary |

The driver is [Xaloqi/zephyr-virtio-can](https://github.com/Xaloqi/zephyr-virtio-can) (Apache-2.0),
pinned in `versions.env`. Set `VIRTIO_CAN_MODULE=<dir>` to use a local checkout instead.

## What this branch changes outside this directory

- `xenvm/scripts/linux.config`: adds CAN, vcan, ISO-TP, `XEN_VIRTIO` and
  `XEN_PRIVCMD_EVENTFD` for Dom0/DomD. xen-vhost-frontend needs the privcmd
  ioeventfd/irqfd ioctls.
- `src/main.c` and `CMakeLists.txt`: `DIAG_ENTROPY_SEEDS` now works for the CAN
  variant too. Before, it was DoIP only, and the CAN variant repeated its seeds on
  every boot.
- `boards/xenvm_can.{conf,overlay}`: the CAN variant for xenvm. virtio-can is
  `can0`, virtio-rng is `zephyr,entropy`. `CONFIG_REBOOT=y` works around EDS#511.

## Patches to third-party code (`patches/`)

| Patch | Why |
|---|---|
| xen-vhost-frontend: `("can", 24)`, `("rng", 4)` | Only i2c, fs and gpio were listed |
| xen-vhost-frontend: read of DriverFeatures | Zephyr's virtio_mmio does a read-modify-write of this write-only register. The frontend failed the ioreq, and the vCPU then waited forever |
| xen-vhost-frontend: negotiate on FEATURES_OK | It negotiated on the first DriverFeatures write to selector 0, which is Linux's order. Zephyr's virtio-entropy never writes selector 0 |
| xen-vhost-frontend: kick on a userspace QUEUE_NOTIFY | The kernel's ioeventfd and this thread race for the same ioreq. When the thread won, the kick was lost (EDS stalled in 3 of 6 boots before the fix, 0 of 5 after) |
| xen-vhost-frontend: log ioreq errors | Errors were dropped (`.ok()`), so the guest hung with no trace |
| vireshk/vhost: `Can = 36`, 3 queues; `Rng` 1 queue | The device table |
| xen-sys: `XEN_DOMCTL_INTERFACE_VERSION` 0x16 → 0x18 | Xen 4.22. The `getdomaininfo` layout is unchanged up to the trailing arch fields |

DomD also runs `harness/xs-sock-relay.py`. xen-vhost-frontend's xenstore client
connects only to xenstored's Unix socket, and that socket exists only in Dom0. The
relay serves it in DomD over `/dev/xen/xenbus`.
