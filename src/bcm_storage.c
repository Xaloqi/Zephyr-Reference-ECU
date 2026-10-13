// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Xaloqi
/*
 * =============================================================================
 * Xaloqi Zephyr-Reference-ECU
 * FILE: src/bcm_storage.c
 *
 * PURPOSE: Phase 1 implementation of the storage boundary declared in
 *          bcm_storage.h — a RAM-backed stub. native_sim has no real flash,
 *          so there is nothing to persist across a process restart; this
 *          file says so rather than pretending otherwise. See bcm_storage.h
 *          for what Phase 2 (real hardware) changes.
 * =============================================================================
 */

#include "bcm_storage.h"

#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(bcm_storage, LOG_LEVEL_INF);

static uint32_t s_door_cycle_count;

void bcm_storage_init(void)
{
    s_door_cycle_count = 0U;
    LOG_WRN("Phase 1 RAM-backed stub — door cycle count does NOT survive a "
            "reset on native_sim. Real persistence lands with the Phase 2 "
            "hardware board overlay.");
}

uint32_t bcm_storage_load_door_cycle_count(void)
{
    return s_door_cycle_count;
}

void bcm_storage_save_door_cycle_count(uint32_t count)
{
    s_door_cycle_count = count;
}
