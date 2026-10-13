// File: generated/routine_handlers.c
// GENERATED — do NOT edit manually, EXCEPT for the four [APP HOOK] bodies
// below (same precedent as EDS's own examples/vehicle_state_ecu). Each
// [APP HOOK] marker is exactly what to re-apply if this file is ever
// regenerated from the YAML — see src/bcm_state.h and README.md, and the
// configure-time check in CMakeLists.txt that fails loudly if a marker
// goes missing after a regeneration.
// ECU: ReferenceBCM  v0.1.0  Generated: 2026-10-13T18:43:55Z

#include "routine_handlers.h"
#include "routine_database.h"
#include "uds_types.h"
#include "bcm_state.h"

/* [APP HOOK] RID 0x0420 — DoorLockAll : startRoutine */
uds_status_t routine_start_doorlockall(
    const uint8_t *opt_buf, uint8_t opt_len,
    uint8_t *result_buf, uint8_t result_buf_len, uint8_t *result_len)
{
    (void)opt_buf; (void)opt_len;
    return bcm_state_doorlock_start(result_buf, result_buf_len, result_len);
}

/* [APP HOOK] RID 0x0420 — DoorLockAll : requestRoutineResults */
uds_status_t routine_results_doorlockall(
    uint8_t *result_buf, uint8_t result_buf_len, uint8_t *result_len)
{
    return bcm_state_doorlock_results(result_buf, result_buf_len, result_len);
}

/* [APP HOOK] RID 0x0421 — WindowCalibrate : startRoutine */
uds_status_t routine_start_windowcalibrate(
    const uint8_t *opt_buf, uint8_t opt_len,
    uint8_t *result_buf, uint8_t result_buf_len, uint8_t *result_len)
{
    (void)opt_buf; (void)opt_len;
    return bcm_state_windowcal_start(result_buf, result_buf_len, result_len);
}

/* [APP HOOK] RID 0x0421 — WindowCalibrate : requestRoutineResults */
uds_status_t routine_results_windowcalibrate(
    uint8_t *result_buf, uint8_t result_buf_len, uint8_t *result_len)
{
    return bcm_state_windowcal_results(result_buf, result_buf_len, result_len);
}

/* Register all routines with routine_database */
uds_status_t routine_handlers_register_all(void)
{
    uds_status_t status;
    routine_entry_t entry;

    /* RID 0x0420 — DoorLockAll */
    entry.rid            = (uint16_t)1056U;
    entry.support_flags  = (uint8_t)(ROUTINE_SUPPORT_START | ROUTINE_SUPPORT_RESULTS);
    entry.min_session    = (uint8_t)UDS_SESSION_EXTENDED;
    entry.security_level = (uint8_t)1U;
    entry.start_cb       = routine_start_doorlockall;
    entry.stop_cb        = NULL;
    entry.results_cb     = routine_results_doorlockall;
    entry.description    = "DoorLockAll";
    status = routine_database_register(&entry);
    if (status != UDS_STATUS_OK) { return status; }

    /* RID 0x0421 — WindowCalibrate */
    entry.rid            = (uint16_t)1057U;
    entry.support_flags  = (uint8_t)(ROUTINE_SUPPORT_START | ROUTINE_SUPPORT_RESULTS);
    entry.min_session    = (uint8_t)UDS_SESSION_EXTENDED;
    entry.security_level = (uint8_t)1U;
    entry.start_cb       = routine_start_windowcalibrate;
    entry.stop_cb        = NULL;
    entry.results_cb     = routine_results_windowcalibrate;
    entry.description    = "WindowCalibrate";
    status = routine_database_register(&entry);
    if (status != UDS_STATUS_OK) { return status; }

    return UDS_STATUS_OK;
}
