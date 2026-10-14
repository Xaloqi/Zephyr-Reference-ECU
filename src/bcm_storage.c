// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Xaloqi
/*
 * =============================================================================
 * Xaloqi Zephyr-Reference-ECU
 * FILE: src/bcm_storage.c
 *
 * PURPOSE: Persists the door-actuation cycle count through EDS's own
 *          nvm_store (see bcm_storage.h for why this module uses EDS's
 *          store rather than a separate mechanism).
 *
 * KEY SPACE: nvm_store.h documents NVM_KEY_0x0001-0x0006 as reserved for
 *          EDS's own records and explicitly sanctions application-defined
 *          keys outside that range ("a customer application may define
 *          further keys of its own whose format this stack knows nothing
 *          about"). BCM_NVM_KEY_DOOR_CYCLE_COUNT (0x0010) is this module's
 *          one key, chosen with headroom to spare.
 *
 * FAILURE POSTURE: matches EDS's own convention elsewhere in this stack --
 *          a read/write failure is logged and degrades to an in-memory
 *          value for this boot, not a fatal error. A door-cycle count that
 *          fails to persist is an availability concern, not a safety one.
 * =============================================================================
 */

#include "bcm_storage.h"

#include "nvm_store.h"

#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(bcm_storage, LOG_LEVEL_INF);

/** Application-defined NVM key -- outside nvm_store.h's reserved
 *  NVM_KEY_0x0001-0x0006 range for EDS's own records. */
#define BCM_NVM_KEY_DOOR_CYCLE_COUNT ((uint16_t)0x0010U)

static uint32_t s_door_cycle_count;

void bcm_storage_init(void)
{
    size_t   read_len = 0U;
    uint32_t stored    = 0U;

    s_door_cycle_count = 0U;

    if (!nvm_store_is_ready()) {
        LOG_WRN("NVM store not ready — door cycle count starts at 0 "
                "this boot and will not persist.");
        return;
    }

    const uds_status_t status = nvm_store_read(
        BCM_NVM_KEY_DOOR_CYCLE_COUNT, &stored, sizeof(stored), &read_len);

    if (status == UDS_STATUS_OK && read_len == sizeof(stored)) {
        s_door_cycle_count = stored;
        LOG_INF("Door cycle count restored from NVM: %u",
                (unsigned)s_door_cycle_count);
    } else if (status == UDS_STATUS_ERR_DID_NOT_FOUND) {
        LOG_INF("No persisted door cycle count yet (first boot) — "
                "starting at 0.");
    } else {
        LOG_WRN("Door cycle count NVM read failed: 0x%02X — starting at 0 "
                "this boot.", (unsigned)status);
    }
}

uint32_t bcm_storage_load_door_cycle_count(void)
{
    return s_door_cycle_count;
}

void bcm_storage_save_door_cycle_count(uint32_t count)
{
    s_door_cycle_count = count;

    if (!nvm_store_is_ready()) {
        return;
    }

    const uds_status_t status = nvm_store_write(
        BCM_NVM_KEY_DOOR_CYCLE_COUNT, &count, sizeof(count));

    if (status != UDS_STATUS_OK) {
        LOG_WRN("Door cycle count NVM write failed: 0x%02X — new value "
                "(%u) held in RAM only this boot.", (unsigned)status,
                (unsigned)count);
    }
}
