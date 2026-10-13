// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Xaloqi
/*
 * =============================================================================
 * Xaloqi Zephyr-Reference-ECU
 * FILE: src/bcm_debounce.c
 *
 * PURPOSE: See bcm_debounce.h. Deliberately dependency-free so it can be
 *          unit-tested with plain gcc — see tests/test_bcm_debounce.c.
 * =============================================================================
 */

#include "bcm_debounce.h"

void bcm_debounce_init(bcm_debounce_t *d)
{
    d->set_ticks  = 0U;
    d->heal_ticks = 0U;
    d->active     = false;
}

bool bcm_debounce_update(bcm_debounce_t *d, bool condition_held, uint8_t threshold_ticks)
{
    uint8_t threshold = (threshold_ticks == 0U) ? (uint8_t)1U : threshold_ticks;

    if (condition_held) {
        d->heal_ticks = 0U;
        if (d->set_ticks < threshold) {
            d->set_ticks++;
        }
        if ((!d->active) && (d->set_ticks >= threshold)) {
            d->active = true;
        }
    } else {
        d->set_ticks = 0U;
        if (d->heal_ticks < threshold) {
            d->heal_ticks++;
        }
        if (d->active && (d->heal_ticks >= threshold)) {
            d->active = false;
        }
    }

    return d->active;
}
