// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Xaloqi
/*
 * =============================================================================
 * Xaloqi Zephyr-Reference-ECU
 * FILE: src/bcm_state.h
 *
 * PURPOSE: Application logic for ReferenceBCM — a Body Control Module
 *          reference: door-lock state, a window-position monitor, two DTC
 *          triggers, and the C bodies behind the two RoutineControl
 *          actuations (RID 0x0420 DoorLockAll, RID 0x0421 WindowCalibrate).
 *
 *          This is the part a forker is expected to replace. Diagnostics
 *          (EDS, wired in src/main.c) is the part they are not.
 *
 * THREADING: bcm_state_monitor_tick() is called from diag_task_entry()'s own
 *          loop in src/main.c — the same thread that dispatches UDS requests
 *          (including the 0x2E writes to the two body-state DIDs). Matches
 *          EDS's own examples/vehicle_state_ecu precedent: the generated DID
 *          backing stores have no locking of their own, so a second thread
 *          reading them would race the UDS dispatch thread's writes.
 * =============================================================================
 */

#ifndef BCM_STATE_H
#define BCM_STATE_H

#include "uds_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/** One-time init. Call once from main() before the diag task starts. */
void bcm_state_init(void);

/**
 * @brief Monitor tick. Call once every ~100 ms from diag_task_entry()'s loop.
 *
 * Reads the two body-state DIDs back through their generated accessors,
 * runs the door-ajar and window-stall DTC monitors, and steps any routine
 * in progress (WindowCalibrate's asynchronous walk).
 */
void bcm_state_monitor_tick(void);

/* --------------------------------------------------------------------------
 * RoutineControl bodies — called from generated/routine_handlers.c's four
 * stub bodies (the one hand-edited "generated/ delta" this repo makes; see
 * CMakeLists.txt and the banner at the top of that file).
 * -------------------------------------------------------------------------- */

/** RID 0x0420 startRoutine — lock all doors, arm the door-ajar monitor. */
uds_status_t bcm_state_doorlock_start(
    uint8_t *result_buf, uint8_t result_buf_len, uint8_t *result_len);

/** RID 0x0420 requestRoutineResults — [lock_state, door_status_bitmask]. */
uds_status_t bcm_state_doorlock_results(
    uint8_t *result_buf, uint8_t result_buf_len, uint8_t *result_len);

/** RID 0x0421 startRoutine — begin the asynchronous window travel-learn walk. */
uds_status_t bcm_state_windowcal_start(
    uint8_t *result_buf, uint8_t result_buf_len, uint8_t *result_len);

/** RID 0x0421 requestRoutineResults — poll the calibration walk's verdict. */
uds_status_t bcm_state_windowcal_results(
    uint8_t *result_buf, uint8_t result_buf_len, uint8_t *result_len);

#ifdef __cplusplus
}
#endif

#endif /* BCM_STATE_H */
