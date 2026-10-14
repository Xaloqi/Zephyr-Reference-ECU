// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Xaloqi
/*
 * =============================================================================
 * Xaloqi Zephyr-Reference-ECU
 * FILE: src/main_doip.c
 *
 * PURPOSE: ReferenceBCM served over DoIP (ISO 13400-2) instead of ISO-TP
 *          CAN — Phase 4's DoIP capability. Same application (door-lock
 *          state, window monitor, persisted cycle counter — see
 *          src/bcm_state.c) as src/main.c, different transport.
 *
 *          This is a SEPARATE, ALTERNATE entry point, not a second
 *          transport running alongside CAN in the same image. Xaloqi EDS
 *          ships no example, and no proven architecture, for running CAN
 *          and DoIP concurrently against the same uds_server_ctx_t safely
 *          — EDS's own architecture note (EDS#197, "diagnostic executor")
 *          designed that and deliberately deferred building it, precisely
 *          because the two dispatch paths would need to share the exact
 *          same session/security locking discipline with no shipped
 *          example to validate it against. Building that concurrency
 *          ourselves, unproven, would be a materially larger and riskier
 *          commitment than "add DoIP" — the same shape of decision as
 *          secure boot's EDS#319 exclusion (see src/main.c's sibling
 *          — no, see README.md "Phase 4"). CMakeLists.txt's
 *          DIAG_DOIP_ONLY_BUILD option selects this file INSTEAD OF
 *          src/main.c, never both.
 *
 *          Adapted from EDS's own examples/basic_ecu_doip/src/main.c —
 *          not re-derived. See that file for the full EDS#191/#192/#353
 *          history behind the UDS tick task and the DoIP/tick-task lock
 *          pair this file reuses verbatim.
 *
 * TARGET:  native_sim (loopback only — see boards/native_sim_doip.conf)
 *          and nucleo_h753zi (real Ethernet — see
 *          boards/nucleo_h753zi_doip.conf and README.md "Phase 4" for the
 *          JP6/JP7 jumper and host static-IP setup it requires).
 *
 * THREAD MODEL:
 *   main()        — init -> uds_generated_init -> start tick + DoIP -> return
 *   uds_tick_task — 1 ms poll loop: uds_server_tick_1ms() + uds_periodic_tick_1ms()
 *                   + bcm_state_monitor_tick() (same app logic as src/main.c,
 *                   same divisor-based ~100 ms cadence inside that function).
 *                   [EDS#191] A DoIP-only build has no CAN diag_task, so
 *                   without this thread the S3 session timeout and the
 *                   SecurityAccess lockout countdown never progress.
 *   doip_thread   — started via a semaphore (zephyr_lwip.c), runs
 *                   eds_doip_server_run().
 *
 * BUILDING:
 *   west build -b native_sim .    -- -DDIAG_DOIP_ONLY_BUILD=ON
 *   west build -b nucleo_h753zi . -- -DDIAG_DOIP_ONLY_BUILD=ON \
 *       -DEXTRA_CONF_FILE=boards/nucleo_h753zi_doip.conf
 *
 * SAFETY   : Reference application — not safety-assessed.
 * STANDARD : MISRA C:2012 alignment intended.
 * LICENSE  : Apache-2.0 (this application layer). EDS itself is dual-
 *            licensed GPL-2.0 / commercial — see COMMERCIAL_NOTICE.md.
 * =============================================================================
 */

/* --------------------------------------------------------------------------
 * EDS stack headers
 * -------------------------------------------------------------------------- */
#include "uds_types.h"
#include "uds_server.h"
#include "uds_security_algo.h"
#include "uds_periodic.h"
#include "uds_session.h"

/* --------------------------------------------------------------------------
 * DoIP platform headers
 * -------------------------------------------------------------------------- */
#include "platform_doip.h"   /* eds_doip_platform_start() */
#include "doip_server.h"     /* DOIP_PORT */
#include "zephyr_mutex.h"
#include "nvm_store.h"

/* --------------------------------------------------------------------------
 * Generated headers (from diagnostics_config.yaml via EDS's codegen.py)
 * -------------------------------------------------------------------------- */
#include "uds_init.h"
#include "generated_config.h"

/* --------------------------------------------------------------------------
 * Application logic
 * -------------------------------------------------------------------------- */
#include "bcm_state.h"
#include "bcm_storage.h"

/* --------------------------------------------------------------------------
 * Zephyr headers
 * -------------------------------------------------------------------------- */
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/flash.h>
#include <zephyr/logging/log.h>
#include <zephyr/storage/flash_map.h>

LOG_MODULE_REGISTER(reference_bcm_doip, LOG_LEVEL_INF);

/* =============================================================================
 * DoIP ECU configuration — standard xaloqi-tester defaults, same values
 * EDS's own examples/basic_ecu_doip uses, so the free tester's DoipBus
 * default constructor args work unchanged against this ECU too.
 * ============================================================================= */

#define DOIP_ECU_LOGICAL_ADDR   (0xE400U)

#ifndef CONFIG_DIAG_TICK_TASK_STACK_SIZE
#define CONFIG_DIAG_TICK_TASK_STACK_SIZE   (2048U)
#endif
#ifndef CONFIG_DIAG_TICK_TASK_PRIORITY
#define CONFIG_DIAG_TICK_TASK_PRIORITY     (5)
#endif

K_THREAD_STACK_DEFINE(s_tick_stack, CONFIG_DIAG_TICK_TASK_STACK_SIZE);
static struct k_thread s_tick_thread;

/* [EDS#353] uds_tick_task and doip_thread both touch uds_server_ctx_t with
 * no prior synchronization otherwise — same lock pair EDS's own
 * basic_ecu_doip wraps both call sites with. */
static diag_mutex_t s_session_lock;
static diag_mutex_t s_security_lock;

static void doip_lock_cb(void)
{
    (void)diag_mutex_lock(&s_session_lock);
    (void)diag_mutex_lock(&s_security_lock);
}

static void doip_unlock_cb(void)
{
    (void)diag_mutex_unlock(&s_security_lock);
    (void)diag_mutex_unlock(&s_session_lock);
}

static void s_on_session_change(uds_session_type_t old_sess,
                                uds_session_type_t new_sess)
{
    (void)old_sess;
    if (new_sess == UDS_SESSION_DEFAULT) {
        (void)uds_periodic_cancel_all();
    }
}

/* =============================================================================
 * UDS tick task [EDS#191] — also drives bcm_state_monitor_tick(), since
 * there is no CAN diag_task thread in this build to do it instead.
 * ============================================================================= */

static void uds_tick_task_entry(void *p1, void *p2, void *p3)
{
    uds_server_ctx_t *srv = (uds_server_ctx_t *)p1;
    (void)p2;
    (void)p3;

    LOG_INF("UDS tick task started");

    while (true) {
        k_msleep(1);
        (void)diag_mutex_lock(&s_session_lock);
        (void)diag_mutex_lock(&s_security_lock);
        (void)uds_server_tick_1ms(srv);
        (void)uds_periodic_tick_1ms();
        (void)diag_mutex_unlock(&s_security_lock);
        (void)diag_mutex_unlock(&s_session_lock);

        bcm_state_monitor_tick();
    }
}

/* =============================================================================
 * main()
 * ============================================================================= */

int main(void)
{
    uds_status_t      status;
    uds_server_ctx_t *srv = NULL;

    LOG_INF("Xaloqi Zephyr-Reference-ECU: ReferenceBCM (DoIP) starting");
    LOG_INF("DoIP logical address: 0x%04X  port: %u",
            (unsigned)DOIP_ECU_LOGICAL_ADDR, (unsigned)DOIP_PORT);

    LOG_WRN("[SEC] Using placeholder AES keys — inject OEM keys before production.");
    (void)uds_security_algo_set_rng_cb(NULL);

    /* Same native_sim-vs-real-hardware split as src/main.c — see that
     * file's identical comment for the FIXED_PARTITION_* rationale. This
     * build has no watchdog instance at all (zephyr_wdt.c isn't compiled
     * into DIAG_DOIP_ONLY_BUILD -- see CMakeLists.txt), so unlike main.c
     * there is no nvm_store_append_set_wdt() call to make here; EDS
     * documents that call as optional. */
#if defined(CONFIG_BOARD_NATIVE_SIM)
    status = nvm_store_init(NULL);
#else
    {
        const struct device    *nvs_dev = FIXED_PARTITION_DEVICE(eds_nvs_slot);
        const off_t              nvs_off = FIXED_PARTITION_OFFSET(eds_nvs_slot);
        const size_t              nvs_sz = FIXED_PARTITION_SIZE(eds_nvs_slot);
        struct flash_pages_info  page_info;
        int rc = flash_get_page_info_by_offs(nvs_dev, nvs_off, &page_info);

        if (rc != 0) {
            LOG_ERR("NVM store: flash_get_page_info_by_offs failed: %d", rc);
            status = UDS_STATUS_ERR_PLATFORM;
        } else {
            const nvm_store_cfg_t nvm_cfg = {
                .flash_dev    = (const void *)nvs_dev,
                .flash_offset = (uint32_t)nvs_off,
                .sector_size  = (uint32_t)page_info.size,
                .sector_count = (uint8_t)(nvs_sz / page_info.size),
            };

            status = nvm_store_init(&nvm_cfg);
        }
    }
#endif
    if (status != UDS_STATUS_OK) {
        LOG_ERR("NVM store init failed: 0x%02X — DTC mirror and the "
                "persisted door-cycle count will not survive reset this "
                "run.", (unsigned)status);
    }

    /*
     * [EDS#304] bcm_storage_init() (via bcm_state_init()) now persists
     * BCM_DoorCycleCount through EDS's own nvm_store, so it must run after
     * nvm_store_init() above, not before. See src/bcm_storage.c.
     */
    bcm_storage_init();
    bcm_state_init();

    /*
     * UDS stack init — DoIP build passes NULL for the CAN transport: the
     * stack is driven by the DoIP server thread, not a CAN poll loop.
     * generated/uds_init.c compiles out isotp_init() under
     * EDS_DOIP_ONLY_BUILD (see CMakeLists.txt's DIAG_DOIP_ONLY_BUILD
     * option, which defines that macro for this build).
     */
    status = uds_generated_init(NULL, 0U, 0U);
    if (status != UDS_STATUS_OK) {
        LOG_ERR("UDS stack init failed: 0x%02X", (unsigned)status);
        return -1;
    }

    srv = uds_generated_get_server();
    if (srv == NULL) {
        LOG_ERR("UDS server context NULL after init.");
        return -1;
    }

    (void)uds_periodic_init();
    (void)uds_session_register_change_cb(srv->cfg.session_ctx,
                                          s_on_session_change);

    LOG_INF("UDS stack ready: %u DIDs  %u DTCs",
            (unsigned)GEN_DID_COUNT, (unsigned)GEN_DTC_COUNT);

    if ((diag_mutex_init(&s_session_lock)  != UDS_STATUS_OK) ||
        (diag_mutex_init(&s_security_lock) != UDS_STATUS_OK)) {
        LOG_ERR("Mutex init failed.");
        return -1;
    }
    eds_doip_set_lock_callbacks(doip_lock_cb, doip_unlock_cb);

    (void)k_thread_create(
        &s_tick_thread, s_tick_stack,
        K_THREAD_STACK_SIZEOF(s_tick_stack),
        uds_tick_task_entry,
        (void *)srv, NULL, NULL,
        CONFIG_DIAG_TICK_TASK_PRIORITY, 0U, K_NO_WAIT
    );
    k_thread_name_set(&s_tick_thread, "uds_tick_task");

    status = eds_doip_platform_start(DOIP_ECU_LOGICAL_ADDR, DOIP_PORT, srv);
    if (status != UDS_STATUS_OK) {
        LOG_ERR("DoIP platform start failed: 0x%02X", (unsigned)status);
        return -1;
    }

    LOG_INF("DoIP server activated — awaiting TCP connections on port %u",
            (unsigned)DOIP_PORT);

    return 0;
}
