# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
# Both DomD image recipes (rpi5-image-xt-domd-vc4 and -v4h, which SoDeV builds
# by default): the virtio-can backends, the DomZ-CAN image and the bench tools.
# xen-tools-xl and xen-tools-xenstore (xenstore-ls) are already in SoDeV's DomD.
IMAGE_INSTALL:append = " xaloqi-domz-can"
