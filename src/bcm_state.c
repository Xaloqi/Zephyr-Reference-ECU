// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Xaloqi
/*
 * =============================================================================
 * Xaloqi Zephyr-Reference-ECU
 * FILE: src/bcm_state.c
 *
 * PURPOSE: Door-lock state, window monitor, DTC triggers, and RoutineControl
 *          bodies for ReferenceBCM. See bcm_state.h for the threading note.
 *
 * DOOR STATUS BYTE (0x0410, tester-injected — native_sim has no real door
 * sensors): bit0=FL bit1=FR bit2=RL bit3=RR, 1 = open.
 *
 * DTC TRIGGERS (both evaluated every monitor tick):
 *
 *   0x041064 "Door ajar timeout" — any door bit set in BCM_DoorStatus while
 *     the body controller is in the locked state (set by RID 0x0420
 *     DoorLockAll), continuously, for BCM_DEBOUNCE_TICKS_DOOR_AJAR ticks.
 *     There is no "unlock" routine in this reference, so once locked the
 *     monitor stays armed for the rest of the run — document, don't hide.
 *
 *   0x041165 "Window actuation stall" — BCM_WindowPosition_pct written
 *     above its nominal 0-100 range (101-255). A real window motor reports
 *     an obstruction through current-sense; this reference has no simulated
 *     motor current, so an out-of-range commanded position stands in as the
 *     fault-injection means a test campaign uses to provoke it on demand.
 *     Clears when a valid (<=100) position is written and held past the
 *     heal debounce.
 * =============================================================================
 */

#include "bcm_state.h"
#include "bcm_storage.h"
#include "bcm_debounce.h"      /* the pure, host-testable piece — see tests/ */

#include "did_handlers.h"      /* generated — did_read_bcm_*() / did_write_bcm_doorcyclecount() */
#include "dtc_database.h"
#include "uds_types.h"

#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(bcm_state, LOG_LEVEL_INF);

/* =============================================================================
 * Tunables
 * ============================================================================= */

/* bcm_state_monitor_tick() is called once every diag_task loop iteration
 * (~1 ms, see src/main.c's on_tick()); this divisor turns that into a
 * ~100 ms monitor cadence, matching EDS's own vehicle_state_ecu precedent. */
#define BCM_MONITOR_TICK_DIVISOR        (100U)

#define BCM_DOOR_BITS_MASK              (0x0FU)   /* FL/FR/RL/RR, bits 0-3 */
#define BCM_WINDOW_NOMINAL_MAX_PCT      (100U)

#define BCM_DEBOUNCE_TICKS_DOOR_AJAR    (5U)      /* ~500 ms at 100 ms/tick */
#define BCM_DEBOUNCE_TICKS_WINDOW_STALL (3U)      /* ~300 ms at 100 ms/tick */

#define BCM_DTC_DOOR_AJAR               (0x041064UL)
#define BCM_DTC_WINDOW_STALL            (0x041165UL)

#define BCM_LOCK_ACK_STARTED            (0x01U)   /* startRoutine response byte */

#define BCM_CAL_RESULT_IN_PROGRESS      (0x00U)
#define BCM_CAL_RESULT_PASS             (0x01U)
#define BCM_CAL_STEP_COUNT              (4U)      /* learn-closed, settle, learn-open, settle */

/* =============================================================================
 * State — single-threaded (diag task only, see bcm_state.h)
 * ============================================================================= */

static bool     s_lock_state;            /* set by RID 0x0420, never cleared */
static uint32_t s_door_cycle_count;      /* mirrors bcm_storage, pushed to the DID */

static bcm_debounce_t s_ajar_debounce;
static bcm_debounce_t s_stall_debounce;

static bool     s_cal_active;
static uint8_t  s_cal_step;              /* 0..BCM_CAL_STEP_COUNT */
static uint8_t  s_cal_learned_min_pct;
static uint8_t  s_cal_learned_max_pct;

/* =============================================================================
 * Helpers
 * ============================================================================= */

static uint8_t bcm_read_u8(did_read_cb_fn read_fn)
{
    uint8_t  buf[1];
    uint16_t out_len = 0U;

    if (read_fn(buf, (uint16_t)sizeof(buf), &out_len) != UDS_STATUS_OK) {
        return 0U;
    }
    if (out_len != (uint16_t)sizeof(buf)) {
        return 0U;
    }
    return buf[0];
}

static void bcm_push_door_cycle_count(uint32_t count)
{
    uint8_t buf[4];

    buf[0] = (uint8_t)((count >> 24U) & 0xFFU);
    buf[1] = (uint8_t)((count >> 16U) & 0xFFU);
    buf[2] = (uint8_t)((count >> 8U)  & 0xFFU);
    buf[3] = (uint8_t)(count & 0xFFU);
    (void)did_write_bcm_doorcyclecount(buf, (uint16_t)sizeof(buf));
}

/* =============================================================================
 * Public API
 * ============================================================================= */

void bcm_state_init(void)
{
    s_lock_state           = false;
    bcm_debounce_init(&s_ajar_debounce);
    bcm_debounce_init(&s_stall_debounce);
    s_cal_active           = false;
    s_cal_step             = 0U;
    s_cal_learned_min_pct  = 0U;
    s_cal_learned_max_pct  = 0U;

    s_door_cycle_count = bcm_storage_load_door_cycle_count();
    bcm_push_door_cycle_count(s_door_cycle_count);
}

void bcm_state_monitor_tick(void)
{
    static uint32_t s_divisor_count;
    uint8_t door_status;
    uint8_t window_pct;

    s_divisor_count++;
    if ((s_divisor_count % BCM_MONITOR_TICK_DIVISOR) != 0U) {
        return;
    }

    door_status = bcm_read_u8(did_read_bcm_doorstatus);
    window_pct  = bcm_read_u8(did_read_bcm_windowposition_pct);

    /* ── 0x041064: door ajar while locked ───────────────────────────────── */
    {
        bool was_active = s_ajar_debounce.active;
        bool condition  = s_lock_state && ((door_status & (uint8_t)BCM_DOOR_BITS_MASK) != 0U);
        bool now_active = bcm_debounce_update(&s_ajar_debounce, condition,
                                               (uint8_t)BCM_DEBOUNCE_TICKS_DOOR_AJAR);

        if (now_active && !was_active) {
            LOG_WRN("DTC door-ajar set: door_status=0x%02X while locked", door_status);
            (void)dtc_database_set_status(BCM_DTC_DOOR_AJAR,
                (uint8_t)(DTC_STATUS_TEST_FAILED |
                          DTC_STATUS_TEST_FAILED_THIS_OPERATION_CYCLE |
                          DTC_STATUS_CONFIRMED_DTC));
        } else if (!now_active && was_active) {
            LOG_INF("DTC door-ajar cleared: all doors closed or no longer locked");
            (void)dtc_database_set_status(BCM_DTC_DOOR_AJAR, (uint8_t)0x00U);
        }
        (void)dtc_database_set_fault_counter(BCM_DTC_DOOR_AJAR, s_ajar_debounce.set_ticks);
    }

    /* ── 0x041165: window position commanded out of nominal range ──────── */
    {
        bool was_active = s_stall_debounce.active;
        bool condition  = window_pct > (uint8_t)BCM_WINDOW_NOMINAL_MAX_PCT;
        bool now_active = bcm_debounce_update(&s_stall_debounce, condition,
                                               (uint8_t)BCM_DEBOUNCE_TICKS_WINDOW_STALL);

        if (now_active && !was_active) {
            LOG_WRN("DTC window-stall set: commanded position=%u out of 0-100 range", window_pct);
            (void)dtc_database_set_status(BCM_DTC_WINDOW_STALL,
                (uint8_t)(DTC_STATUS_TEST_FAILED |
                          DTC_STATUS_TEST_FAILED_THIS_OPERATION_CYCLE |
                          DTC_STATUS_CONFIRMED_DTC));
        } else if (!now_active && was_active) {
            LOG_INF("DTC window-stall cleared: commanded position back in range");
            (void)dtc_database_set_status(BCM_DTC_WINDOW_STALL, (uint8_t)0x00U);
        }
        (void)dtc_database_set_fault_counter(BCM_DTC_WINDOW_STALL, s_stall_debounce.set_ticks);
    }

    /* ── WindowCalibrate async walk ─────────────────────────────────────── */
    if (s_cal_active) {
        if (s_cal_step == 0U) {
            s_cal_learned_min_pct = 0U;    /* learned "fully closed" end stop */
        } else if (s_cal_step == 2U) {
            s_cal_learned_max_pct = (uint8_t)BCM_WINDOW_NOMINAL_MAX_PCT; /* "fully open" */
        }
        s_cal_step++;
        if (s_cal_step >= (uint8_t)BCM_CAL_STEP_COUNT) {
            s_cal_active = false;
            LOG_INF("WindowCalibrate complete: learned range %u..%u%%",
                    s_cal_learned_min_pct, s_cal_learned_max_pct);
        }
    }
}

uds_status_t bcm_state_doorlock_start(
    uint8_t *result_buf, uint8_t result_buf_len, uint8_t *result_len)
{
    if ((result_buf == NULL) || (result_len == NULL)) {
        return UDS_STATUS_ERR_NULL_PTR;
    }
    if (result_buf_len < (uint8_t)1U) {
        return UDS_STATUS_ERR_BUFFER_OVERFLOW;
    }

    s_lock_state = true;
    s_door_cycle_count++;
    bcm_storage_save_door_cycle_count(s_door_cycle_count);
    bcm_push_door_cycle_count(s_door_cycle_count);

    LOG_INF("DoorLockAll: locked, cycle_count=%u", s_door_cycle_count);

    result_buf[0] = (uint8_t)BCM_LOCK_ACK_STARTED;
    *result_len   = 1U;
    return UDS_STATUS_OK;
}

uds_status_t bcm_state_doorlock_results(
    uint8_t *result_buf, uint8_t result_buf_len, uint8_t *result_len)
{
    uint8_t door_status;

    if ((result_buf == NULL) || (result_len == NULL)) {
        return UDS_STATUS_ERR_NULL_PTR;
    }
    if (result_buf_len < (uint8_t)2U) {
        return UDS_STATUS_ERR_BUFFER_OVERFLOW;
    }

    door_status = bcm_read_u8(did_read_bcm_doorstatus);

    result_buf[0] = s_lock_state ? (uint8_t)0x01U : (uint8_t)0x00U;
    result_buf[1] = door_status;
    *result_len   = 2U;
    return UDS_STATUS_OK;
}

uds_status_t bcm_state_windowcal_start(
    uint8_t *result_buf, uint8_t result_buf_len, uint8_t *result_len)
{
    if ((result_buf == NULL) || (result_len == NULL)) {
        return UDS_STATUS_ERR_NULL_PTR;
    }
    if (result_buf_len < (uint8_t)1U) {
        return UDS_STATUS_ERR_BUFFER_OVERFLOW;
    }

    s_cal_active          = true;
    s_cal_step             = 0U;
    s_cal_learned_min_pct  = 0U;
    s_cal_learned_max_pct  = 0U;

    LOG_INF("WindowCalibrate: started");

    result_buf[0] = (uint8_t)BCM_LOCK_ACK_STARTED;
    *result_len   = 1U;
    return UDS_STATUS_OK;
}

uds_status_t bcm_state_windowcal_results(
    uint8_t *result_buf, uint8_t result_buf_len, uint8_t *result_len)
{
    if ((result_buf == NULL) || (result_len == NULL)) {
        return UDS_STATUS_ERR_NULL_PTR;
    }
    if (result_buf_len < (uint8_t)3U) {
        return UDS_STATUS_ERR_BUFFER_OVERFLOW;
    }

    result_buf[0] = s_cal_active ? (uint8_t)BCM_CAL_RESULT_IN_PROGRESS
                                  : (uint8_t)BCM_CAL_RESULT_PASS;
    result_buf[1] = s_cal_learned_min_pct;
    result_buf[2] = s_cal_learned_max_pct;
    *result_len   = 3U;
    return UDS_STATUS_OK;
}
