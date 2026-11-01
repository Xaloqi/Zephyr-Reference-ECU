/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright (c) 2026 Xaloqi */

/*
 * SecurityAccess seed source, shared by src/main.c and src/main_doip.c.
 *
 * Every image that has a zephyr,entropy device (the NUCLEO's hardware RNG,
 * xenvm's virtio-rng) draws its SecurityAccess seeds from it through a TRNG
 * callback registered at start-up. native_sim has no hardware RNG and keeps
 * EDS's documented LFSR fallback (CI / development only).
 *
 * DIAG_USE_ENTROPY is defined when the callback below must be registered.
 * The guards fail the build instead of letting a board with no usable
 * entropy device fall back to the LFSR without anyone noticing.
 */

#ifndef DIAG_ENTROPY_H
#define DIAG_ENTROPY_H

#include <zephyr/devicetree.h>
#include <zephyr/kernel.h>

#if defined(CONFIG_ARCH_POSIX)

/* native_sim: LFSR fallback by design. */

#elif defined(CONFIG_ENTROPY_GENERATOR) && DT_HAS_CHOSEN(zephyr_entropy)

#define DIAG_USE_ENTROPY 1

#include <zephyr/device.h>
#include <zephyr/drivers/entropy.h>

#include "uds_types.h"

static const struct device *const s_entropy_dev =
    DEVICE_DT_GET(DT_CHOSEN(zephyr_entropy));

static uds_status_t s_trng_cb(uint8_t *buf, uint8_t len)
{
    int rc = entropy_get_entropy(s_entropy_dev, buf, (uint16_t)len);

    return (rc == 0) ? UDS_STATUS_OK : UDS_STATUS_ERR_PLATFORM;
}

#elif DT_HAS_CHOSEN(zephyr_entropy)

#error "The board has a zephyr,entropy device but CONFIG_ENTROPY_GENERATOR is off: SecurityAccess seeds would come from the LFSR fallback. Set CONFIG_ENTROPY_GENERATOR=y."

#else

#error "No zephyr,entropy device on this board: SecurityAccess seeds would come from the LFSR fallback. Add one (see boards/*.overlay) or build for native_sim."

#endif

#endif /* DIAG_ENTROPY_H */
