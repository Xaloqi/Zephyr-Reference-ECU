// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Xaloqi
/*
 * =============================================================================
 * Xaloqi Zephyr-Reference-ECU
 * FILE: src/main.c
 *
 * PURPOSE: ReferenceBCM Zephyr application entry point.
 *
 *          A Body Control Module reference: door-lock state and a window
 *          position monitor as DIDs, two DTCs on faults those two signals
 *          can produce, and two RoutineControl actuations — see
 *          src/bcm_state.c for the application logic behind all three, and
 *          src/bcm_storage.c for the persistence boundary behind the
 *          cycle-count DID.
 *
 * TARGET:  native_sim and nucleo_h753zi.
 *
 * THREAD MODEL:
 *   main()       — platform init -> UDS init -> launch diag_task -> return 0
 *   diag_task    — 1 ms poll loop: CAN RX -> ISO-TP -> UDS dispatch -> CAN TX,
 *                  plus a 100 ms-cadence call into bcm_state_monitor_tick()
 *                  (see bcm_state.h for why that logic lives on this thread
 *                  rather than a separate one).
 *
 * BUILDING:
 *   west build -b native_sim .
 *
 * SAFETY   : Reference application — not safety-assessed.
 * STANDARD : MISRA C:2012 alignment intended.
 * LICENSE  : Apache-2.0 (this application layer). EDS itself is dual-
 *            licensed GPL-2.0 / commercial — see COMMERCIAL_NOTICE.md.
 * =============================================================================
 */

/* --------------------------------------------------------------------------
 * Diagnostics stack headers (Xaloqi EDS, pulled in as a west module)
 * -------------------------------------------------------------------------- */
#include "uds_types.h"
#include "uds_server.h"
#include "uds_security_algo.h"
#include "uds_periodic.h"
#include "uds_session.h"
#include "isotp.h"
#include "can_transport.h"
#include "zephyr_port.h"
#include "zephyr_mutex.h"
#include "zephyr_timer.h"
#include "zephyr_wdt.h"
#include "nvm_store.h"
#if defined(DIAG_NVM_BACKEND_APPEND)
#include "nvm_store_append.h"              /* nvm_store_append_set_wdt() */
#endif
#if defined(DIAG_SECURE_BOOT_BUILD)
#include "zephyr_flash_ops.h"              /* zephyr_flash_ops_set_wdt() */
#include "zephyr_mcuboot_image_policy.h"   /* zephyr_mcuboot_image_policy_init() */
#include <zephyr/dfu/mcuboot.h>            /* boot_is_img_confirmed() et al. */
#endif

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
#include <zephyr/drivers/can.h>
#include <zephyr/drivers/flash.h>
#include <zephyr/logging/log.h>
#include <zephyr/storage/flash_map.h>

LOG_MODULE_REGISTER(reference_bcm, LOG_LEVEL_INF);

/* =============================================================================
 * Configuration
 * ============================================================================= */

#define DIAG_CAN_DEV         DEVICE_DT_GET(DT_ALIAS(can0))
#define DIAG_RX_CAN_ID       ((uint32_t)GEN_CAN_RX_ID)   /* 0x7DF */
#define DIAG_TX_CAN_ID       ((uint32_t)GEN_CAN_TX_ID)   /* 0x7E8 */

#ifndef CONFIG_DIAG_TASK_STACK_SIZE
#define CONFIG_DIAG_TASK_STACK_SIZE   (4096U)
#endif

#ifndef CONFIG_DIAG_TASK_PRIORITY
#define CONFIG_DIAG_TASK_PRIORITY     (5)
#endif

/* =============================================================================
 * Static allocations
 * ============================================================================= */

K_THREAD_STACK_DEFINE(s_diag_stack, CONFIG_DIAG_TASK_STACK_SIZE);
static struct k_thread s_diag_thread;

static diag_mutex_t s_session_lock;
static diag_mutex_t s_security_lock;
static diag_timer_t s_tick_timer;
static diag_wdt_t   s_wdt;

/* =============================================================================
 * ISO-TP RX completion callback
 *
 * Called by isotp_process_rx_frame() when a complete UDS PDU is reassembled.
 * Holds the session lock for the duration of dispatch + response transmission.
 * ============================================================================= */

static void on_isotp_rx_complete(
    const uint8_t *data,
    uint32_t       length,
    void          *arg)
{
    uds_server_ctx_t *srv = (uds_server_ctx_t *)arg;
    isotp_ctx_t      *tp  = uds_generated_get_isotp();

    /* Static buffers — no stack allocation of uds_msg_buf_t. */
    static uds_msg_buf_t s_req;
    static uds_msg_buf_t s_resp;

    uint16_t i;

    if ((data == NULL) || (srv == NULL) || (tp == NULL)) { return; }
    if ((length == 0U) || (length > (uint32_t)UDS_MAX_PAYLOAD_LEN)) { return; }

    (void)diag_mutex_lock(&s_session_lock);

    for (i = 0U; i < (uint16_t)length; i++) {
        s_req.data[i] = data[i];
    }
    s_req.length  = (uint16_t)length;
    s_resp.length = 0U;

    (void)uds_server_process_request(srv, &s_req, &s_resp);

    if (s_resp.length > 0U) {
        (void)isotp_transmit(tp, s_resp.data, s_resp.length);
    }

    (void)diag_mutex_unlock(&s_session_lock);

    /* Deferred reset: response is on the wire, now reset. */
    if (srv->pending_reset_type != (uint8_t)0U) {
        uint8_t reset_type = srv->pending_reset_type;
        srv->pending_reset_type = (uint8_t)0U;
        (void)zephyr_port_nvm_flush();
        k_msleep(50);  /* Allow ISO-TP TX to reach the wire before reset (As timer). */
        (void)zephyr_port_ecu_reset(reset_type);
        /* Does not return. */
    }
}

/* =============================================================================
 * 1 ms tick callback — drives ISO-TP and UDS session timers
 * ============================================================================= */

typedef struct { uds_server_ctx_t *srv; isotp_ctx_t *tp; } tick_ctx_t;

static void on_tick(void *arg)
{
    tick_ctx_t *ctx = (tick_ctx_t *)arg;
    if (ctx == NULL) { return; }
    (void)isotp_tick_1ms(ctx->tp);
    (void)uds_server_tick_1ms(ctx->srv);
    (void)uds_periodic_tick_1ms();
}

/* =============================================================================
 * Diagnostics task
 *
 * Folds bcm_state_monitor_tick() into this same loop, on this same thread,
 * immediately after on_tick() — see bcm_state.h for why that matters (it's
 * the thread that also dispatches the 0x2E writes to the two body-state
 * DIDs, and the generated DID backing stores have no locking of their own).
 * ============================================================================= */

static void diag_task_entry(void *p1, void *p2, void *p3)
{
    uds_server_ctx_t *srv = (uds_server_ctx_t *)p1;
    can_transport_t  *can = (can_transport_t  *)p2;
    isotp_ctx_t      *tp  = (isotp_ctx_t      *)p3;

    uds_status_t    status;
    uds_can_frame_t rx_frame;
    bool            frame_ready;
    tick_ctx_t      tick_ctx = { .srv = srv, .tp = tp };

    LOG_INF("ReferenceBCM diag task started");

    if (diag_timer_start(&s_tick_timer) != UDS_STATUS_OK) {
        LOG_ERR("Timer start failed."); return;
    }

    while (true) {
        (void)diag_timer_wait_tick(&s_tick_timer, 2U);

        frame_ready = false;
        status = can_transport_receive(can, &rx_frame, &frame_ready);
        if ((status == UDS_STATUS_OK) && frame_ready) {
            (void)isotp_process_rx_frame(tp, &rx_frame,
                                          on_isotp_rx_complete, srv);
        }

        on_tick(&tick_ctx);
        bcm_state_monitor_tick();

        {
            static uds_msg_buf_t s_periodic_frame;
            while (uds_periodic_pop_due(&s_periodic_frame) == UDS_STATUS_OK) {
                /* Re-queue on ISO-TP busy instead of silently dropping this
                 * period -- isotp_transmit() can legitimately return BUSY
                 * mid multi-frame send; retry on the next 1ms tick rather
                 * than losing the period, and stop draining this tick (the
                 * same busy channel would just fail the next pop too). */
                if (isotp_transmit(tp, s_periodic_frame.data,
                                   (uint32_t)s_periodic_frame.length) != UDS_STATUS_OK) {
                    (void)uds_periodic_requeue_last();
                    break;
                }
            }
        }

        (void)diag_wdt_feed(&s_wdt);
    }
}

/* =============================================================================
 * Session change callback — cancels periodic subscriptions on return to the
 * Default session (including on S3server timeout). Door-lock state is not
 * released here: it models a physical lock, not a diagnostic client hold.
 * ============================================================================= */

static void s_on_session_change(uds_session_type_t old_sess,
                                uds_session_type_t new_sess)
{
    (void)old_sess;
    if (new_sess == UDS_SESSION_DEFAULT) {
        (void)uds_periodic_cancel_all();
    }
}

/* =============================================================================
 * main()
 * ============================================================================= */

int main(void)
{
    uds_status_t      status;
    can_transport_t  *can = NULL;
    uds_server_ctx_t *srv = NULL;
    isotp_ctx_t      *tp  = NULL;

    LOG_INF("Xaloqi Zephyr-Reference-ECU: ReferenceBCM starting");

#if defined(CONFIG_IWDG_STM32_INITIAL_TIMEOUT) && !defined(CONFIG_WDT_DISABLE_AT_BOOT)
    /* Zephyr armed the IWDG before main() and this build relies on reaching
     * the feed loop inside that window (boards/nucleo_h753zi.conf). Uptime
     * starts before the IWDG does, so this overstates elapsed watchdog time
     * — a conservative early warning before a slower pre-main turns into
     * issue #7's silent reset loop. */
    if (k_uptime_get_32() > ((uint32_t)CONFIG_IWDG_STM32_INITIAL_TIMEOUT / 2U)) {
        LOG_WRN("WDT: main() reached at %u ms — over half the %u ms "
                "boot-armed watchdog window.", (unsigned)k_uptime_get_32(),
                (unsigned)CONFIG_IWDG_STM32_INITIAL_TIMEOUT);
    }
#endif

    if (diag_mutex_init(&s_session_lock)  != UDS_STATUS_OK) { return -1; }
    if (diag_mutex_init(&s_security_lock) != UDS_STATUS_OK) { return -1; }

    (void)diag_wdt_init(&s_wdt);

#if defined(DIAG_SECURE_BOOT_BUILD)
    /* [EDS#312] Give the flash-ops layer the same watchdog instance so its
     * chunked erase_step_cb() can bridge the watchdog across one bounded
     * sector-erase call -- STM32H7 flash sector erase can block up to
     * ~4000 ms, far past this build's 100 ms watchdog window. Must run
     * before uds_generated_init() below, which calls zephyr_flash_ops_init().
     * Adapted verbatim from EDS's own examples/safeboot_ecu/src/main.c. */
    zephyr_flash_ops_set_wdt(&s_wdt);
#endif

#if defined(DIAG_NVM_BACKEND_APPEND)
    /* Same reasoning as zephyr_flash_ops_set_wdt() above, for the append-
     * only NVM backend's own one bounded bank-erase call (see
     * platform/zephyr/nvm_store_append.c). Must run before nvm_store_init()
     * below. Adapted verbatim from EDS's own
     * examples/safeboot_ecu/src/main.c. */
    nvm_store_append_set_wdt(&s_wdt);
#endif

    status = diag_timer_init(&s_tick_timer, on_tick, NULL);
    if (status != UDS_STATUS_OK) { LOG_ERR("Timer init failed."); return -1; }

    {
        const zephyr_port_cfg_t port_cfg = {
            .can_dev = DIAG_CAN_DEV,
            /* ISO 15765-4 physical addressing alongside the functional
             * 0x7DF filter above -- a real SOVD/UDS tester (e.g. the
             * Eclipse OpenSOVD CDA) probes with a physical request and
             * will not treat a functional-only ECU as discoverable (same
             * precedent as EDS's own examples/basic_ecu). See README.md
             * "Phase 3". */
            .physical_rx_id = 0x7E0U,
        };
        status = zephyr_port_init(&port_cfg, &can);
        if (status != UDS_STATUS_OK) {
            LOG_ERR("Platform init failed: 0x%02X", (unsigned)status);
            return -1;
        }
    }

    /*
     * native_sim: RAM-backed mock NVM (nvm_store_mock.c), no real flash
     * partition to resolve — nvm_store_init() ignores cfg entirely, NULL
     * is correct there (see EDS's nvm_store.h: "may be NULL on host").
     *
     * nucleo_h753zi: the append-only backend (nvm_store_append.c, EDS#304)
     * against the diag_nvs partition reserved in boards/nucleo_h753zi.overlay
     * — matches CMakeLists.txt's DIAG_NVM_BACKEND_APPEND source selection
     * for this board, and EDS's own examples/safeboot_ecu's identical
     * choice for the same part. nvm_store.c's classic NVS backend cannot
     * mount this partition at all here: STM32H753's uniform 128 KB erase
     * sectors exceed nvs_fs.sector_size's uint16_t range. FIXED_PARTITION_*
     * macros take the DTS *node label* (eds_nvs_slot), not the partition's
     * string "label" property ("diag_nvs") — same distinction EDS's own
     * basic_ecu/src/main.c documents for the identical pattern.
     */
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
     * nvm_store_init() above, not before -- reading from an uninitialized
     * store would fail every boot. See src/bcm_storage.c.
     */
    bcm_storage_init();
    bcm_state_init();

    /*
     * Security algorithm init — no TRNG on native_sim (CI / development
     * build). For production: call uds_security_algo_set_rng_cb() with a
     * real TRNG callback and uds_security_algo_set_level_key() with OEM
     * keys from OTP. See EDS's docs/SECURITY_NOTICE.md.
     */
    LOG_WRN("[SEC] Using placeholder AES keys — inject OEM keys before production.");
    (void)uds_security_algo_set_rng_cb(NULL);

    status = uds_generated_init(can, DIAG_RX_CAN_ID, DIAG_TX_CAN_ID);
    if (status != UDS_STATUS_OK) {
        LOG_ERR("UDS stack init failed: 0x%02X", (unsigned)status);
        return -1;
    }

    srv = uds_generated_get_server();
    tp  = uds_generated_get_isotp();
    if ((srv == NULL) || (tp == NULL)) {
        LOG_ERR("Stack context NULL after init."); return -1;
    }

    (void)uds_periodic_init();
    (void)uds_session_register_change_cb(srv->cfg.session_ctx,
                                          s_on_session_change);

    LOG_INF("UDS stack ready: %u DIDs  %u DTCs  RX=0x%03X TX=0x%03X",
            (unsigned)GEN_DID_COUNT, (unsigned)GEN_DTC_COUNT,
            (unsigned)DIAG_RX_CAN_ID, (unsigned)DIAG_TX_CAN_ID);

#if defined(DIAG_SECURE_BOOT_BUILD)
    /*
     * MCUboot image confirmation — adapted verbatim from EDS's own
     * examples/safeboot_ecu/src/main.c. Non-fatal by design: a defective
     * image that cannot confirm itself rolls back to the previous slot on
     * the next reset, which is the correct safety behaviour, not a bug to
     * work around.
     */
    {
        if (!boot_is_img_confirmed()) {
            int boot_rc = boot_write_img_confirmed();
            if (boot_rc == 0) {
                LOG_INF("[OTA] New image confirmed — rollback guard cleared.");
            } else {
                LOG_ERR("[OTA] boot_write_img_confirmed() err %d — "
                        "MCUboot will roll back on next reset.", boot_rc);
            }
        }
    }

    /*
     * DFU image policy registration — must happen before the diag thread
     * starts accepting CAN traffic, or 0x34 RequestDownload proceeds with
     * no policy. Non-fatal: diagnostics still start, DFU is simply
     * unavailable this power cycle (same posture as a failed NVM init
     * above).
     */
    status = zephyr_mcuboot_image_policy_init();
    if (status != UDS_STATUS_OK) {
        LOG_ERR("[DFU] Image policy registration failed: 0x%02X — "
                "0x34 RequestDownload will be refused.", (unsigned)status);
    } else {
        LOG_INF("[DFU] Image policy registered (SHA-256 digest verify, "
                "boot_request_upgrade on accept). Authenticity comes "
                "entirely from MCUboot's own RSA-2048-PSS signature check "
                "-- see README.md \"Phase 4\" before treating this as more "
                "than that.");
    }
#endif /* DIAG_SECURE_BOOT_BUILD */

    (void)k_thread_create(
        &s_diag_thread, s_diag_stack,
        K_THREAD_STACK_SIZEOF(s_diag_stack),
        diag_task_entry,
        (void *)srv, (void *)can, (void *)tp,
        CONFIG_DIAG_TASK_PRIORITY, 0U, K_NO_WAIT
    );
    k_thread_name_set(&s_diag_thread, "diag_task");

    return 0;
}
