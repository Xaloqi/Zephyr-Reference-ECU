// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Xaloqi
/*
 * =============================================================================
 * Xaloqi Zephyr-Reference-ECU
 * FILE: src/bcm_debounce.h
 *
 * PURPOSE: The debounce logic behind both DTC monitors in src/bcm_state.c,
 *          pulled out on purpose: this file has NO Zephyr or EDS dependency
 *          at all, so it is testable with plain gcc — see tests/. Everything
 *          else in src/ needs the full Zephyr+EDS build to even compile.
 * =============================================================================
 */

#ifndef BCM_DEBOUNCE_H
#define BCM_DEBOUNCE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t set_ticks;    /* consecutive ticks the condition has held */
    uint8_t heal_ticks;   /* consecutive ticks the condition has NOT held */
    bool    active;       /* current debounced state */
} bcm_debounce_t;

/** Reset to the inactive state. */
void bcm_debounce_init(bcm_debounce_t *d);

/**
 * @brief Advance the debounce state machine by one monitor tick.
 *
 * @param d               Debounce state to update.
 * @param condition_held  Whether the raw (un-debounced) fault condition is
 *                         present on this tick.
 * @param threshold_ticks  Consecutive ticks required to flip state in
 *                         either direction. 0 is treated as 1 (an edge on
 *                         the very first tick).
 * @return The debounced `active` state after this tick (same value as
 *         `d->active` on return — returned directly so a caller can read
 *         it without a second field access).
 */
bool bcm_debounce_update(bcm_debounce_t *d, bool condition_held, uint8_t threshold_ticks);

#ifdef __cplusplus
}
#endif

#endif /* BCM_DEBOUNCE_H */
