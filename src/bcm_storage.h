// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Xaloqi
/*
 * =============================================================================
 * Xaloqi Zephyr-Reference-ECU
 * FILE: src/bcm_storage.h
 *
 * PURPOSE: Persistence boundary for application-level state — separate from
 *          EDS's own NVM store, which belongs to the diagnostics layer (DTC
 *          mirror) and is not this module's concern.
 *
 * PHASE 1 (native_sim, no hardware): RAM-backed stub. The API below is the
 *          real, permanent boundary the rest of the app calls through; only
 *          the backing implementation changes in Phase 2.
 *
 * PHASE 2 (NUCLEO-H753ZI): backed by Zephyr's settings subsystem on a
 *          dedicated flash partition (separate from EDS's own "diag_nvs"),
 *          the same persistence mechanism Zephyr applications use generally
 *          — not EDS's. Lands with the hardware board overlay; no caller in
 *          this file changes.
 * =============================================================================
 */

#ifndef BCM_STORAGE_H
#define BCM_STORAGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** One-time init. Call once from main() before the diag task starts. */
void bcm_storage_init(void);

/** Load the persisted door-actuation cycle count (0 if never saved / Phase 1 stub). */
uint32_t bcm_storage_load_door_cycle_count(void);

/** Persist a new door-actuation cycle count. */
void bcm_storage_save_door_cycle_count(uint32_t count);

#ifdef __cplusplus
}
#endif

#endif /* BCM_STORAGE_H */
