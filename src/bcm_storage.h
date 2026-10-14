// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Xaloqi
/*
 * =============================================================================
 * Xaloqi Zephyr-Reference-ECU
 * FILE: src/bcm_storage.h
 *
 * PURPOSE: Persistence boundary for application-level state. The API below
 *          is the real, permanent boundary the rest of the app calls
 *          through; only the backing implementation has changed.
 *
 * BACKING IMPLEMENTATION: EDS's own nvm_store (nvm_store.h), under an
 *          app-defined key (BCM_NVM_KEY_DOOR_CYCLE_COUNT, see bcm_storage.c)
 *          outside EDS's reserved NVM_KEY_* range. Originally planned as a
 *          *separate* mechanism from EDS's NVM store (Zephyr's settings
 *          subsystem, on its own dedicated partition) specifically to keep
 *          this module decoupled from the diagnostics layer. Changed once
 *          [EDS#304]'s real scope became clear: Zephyr's settings subsystem
 *          backs onto the same NVS implementation that's architecturally
 *          incompatible with this chip's 128 KB erase sectors, so a separate
 *          partition would have hit the identical problem and needed its
 *          own from-scratch fix. EDS's own resolution (nvm_store_append.c,
 *          hardware-verified on this exact board family) is a general
 *          key-value store, not DTC-mirror-specific -- reusing it here is
 *          not a layering violation, it is not re-solving a problem EDS
 *          already solved. See src/bcm_storage.c for exactly how.
 * =============================================================================
 */

#ifndef BCM_STORAGE_H
#define BCM_STORAGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** One-time init. Call once from main() AFTER nvm_store_init() has
 *  completed (reads the persisted value) and before the diag task starts. */
void bcm_storage_init(void);

/** Load the persisted door-actuation cycle count (0 if never saved, or if
 *  the NVM store isn't ready this boot). */
uint32_t bcm_storage_load_door_cycle_count(void);

/** Persist a new door-actuation cycle count. */
void bcm_storage_save_door_cycle_count(uint32_t count);

#ifdef __cplusplus
}
#endif

#endif /* BCM_STORAGE_H */
