// File: generated/routine_handlers.h
// GENERATED — do NOT edit manually.
// ECU: ReferenceBCM  v0.1.0  Generated: 2026-10-13T20:48:00Z

#ifndef ROUTINE_HANDLERS_H
#define ROUTINE_HANDLERS_H

#include "uds_types.h"
#include "routine_database.h"

/* Register all routines from diagnostics_config.yaml */
uds_status_t routine_handlers_register_all(void);

/* RID 0x0420 — DoorLockAll */
uds_status_t routine_start_doorlockall(const uint8_t *opt_buf, uint8_t opt_len, uint8_t *result_buf, uint8_t result_buf_len, uint8_t *result_len);
uds_status_t routine_results_doorlockall(uint8_t *result_buf, uint8_t result_buf_len, uint8_t *result_len);

/* RID 0x0421 — WindowCalibrate */
uds_status_t routine_start_windowcalibrate(const uint8_t *opt_buf, uint8_t opt_len, uint8_t *result_buf, uint8_t result_buf_len, uint8_t *result_len);
uds_status_t routine_results_windowcalibrate(uint8_t *result_buf, uint8_t result_buf_len, uint8_t *result_len);

/* RID 0x1001 — SelfTest */
uds_status_t routine_start_selftest(const uint8_t *opt_buf, uint8_t opt_len, uint8_t *result_buf, uint8_t result_buf_len, uint8_t *result_len);

#endif /* ROUTINE_HANDLERS_H */
