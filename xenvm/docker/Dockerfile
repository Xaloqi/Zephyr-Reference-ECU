# Builder for the xenvm harness: cross toolchains for Xen/Linux/QEMU (arm64),
# the Zephyr SDK, and qemu-system-aarch64 to boot the result.
# SPDX-License-Identifier: Apache-2.0
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
RUN dpkg --add-architecture arm64 && apt-get update && apt-get install -y --no-install-recommends \
    crossbuild-essential-arm64 build-essential python3 python3-venv python3-setuptools \
    flex bison bc git ca-certificates cpio file wget xz-utils kmod rsync pkg-config \
    libssl-dev libelf-dev ninja-build meson cmake gperf device-tree-compiler mmdebstrap \
    qemu-system-arm gettext acpica-tools \
    libyajl-dev:arm64 zlib1g-dev:arm64 uuid-dev:arm64 libfdt-dev:arm64 libncurses-dev:arm64 \
    libzstd-dev:arm64 liblzma-dev:arm64 libbz2-dev:arm64 libglib2.0-dev:arm64 libpixman-1-dev:arm64 \
    libaio-dev:arm64 libnl-3-dev:arm64 libnl-route-3-dev:arm64 \
    && rm -rf /var/lib/apt/lists/*

# Zephyr SDK: minimal bundle + the aarch64-zephyr-elf toolchain, checksums pinned.
ARG ZSDK_VER
ARG ZSDK_BASE_URL
ARG ZSDK_MINIMAL_SHA256
ARG ZSDK_AARCH64_SHA256
RUN cd /opt && \
    wget -q ${ZSDK_BASE_URL}/zephyr-sdk-${ZSDK_VER}_linux-x86_64_minimal.tar.xz && \
    wget -q ${ZSDK_BASE_URL}/toolchain_gnu_linux-x86_64_aarch64-zephyr-elf.tar.xz && \
    echo "${ZSDK_MINIMAL_SHA256}  zephyr-sdk-${ZSDK_VER}_linux-x86_64_minimal.tar.xz" | sha256sum -c && \
    echo "${ZSDK_AARCH64_SHA256}  toolchain_gnu_linux-x86_64_aarch64-zephyr-elf.tar.xz" | sha256sum -c && \
    tar xf zephyr-sdk-${ZSDK_VER}_linux-x86_64_minimal.tar.xz && \
    mkdir -p zephyr-sdk-${ZSDK_VER}/gnu && \
    tar xf toolchain_gnu_linux-x86_64_aarch64-zephyr-elf.tar.xz -C zephyr-sdk-${ZSDK_VER}/gnu && \
    rm -f *.tar.xz
ENV ZEPHYR_SDK_INSTALL_DIR=/opt/zephyr-sdk-${ZSDK_VER}

# west + Zephyr's base Python requirements, taken from the pinned Zephyr SHA.
ARG ZEPHYR_REV
RUN python3 -m venv /opt/venv && \
    wget -q -O /tmp/req.txt https://raw.githubusercontent.com/zephyrproject-rtos/zephyr/${ZEPHYR_REV}/scripts/requirements-base.txt && \
    /opt/venv/bin/pip install -q --no-cache-dir west -r /tmp/req.txt && rm /tmp/req.txt
ENV PATH=/opt/venv/bin:${PATH}
