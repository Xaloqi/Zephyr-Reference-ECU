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
 *          transport running alongside CAN in the same image.
 *          CMakeLists.txt's DIAG_DOIP_ONLY_BUILD option selects this file
 *          INSTEAD OF src/main.c, never both. (EDS now ships the
 *          diagnostic executor, EDS#197, and examples/dual_transport_ecu,
 *          a CAN + DoIP reference on it; this repo has not moved its CAN
 *          build onto it, so it still builds one transport per image.)
 *
 *          Adapted from EDS's own examples/basic_ecu_doip/src/main.c —
 *          not re-derived. Like that example, the UDS server is owned by the
 *          diagnostic executor (EDS#197): one thread runs every dispatch,
 *          the 1 ms UDS ticks and this application's monitor tick, and
 *          the DoIP thread posts its requests to it. That replaces the
 *          UDS tick task and the session/security lock pair of EDS#191,
 *          #192 and #353 (Zephyr-Reference-ECU#77).
 *
 * TARGET:  native_sim (loopback only — see boards/native_sim_doip.conf)
 *          and nucleo_h753zi (real Ethernet — see
 *          boards/nucleo_h753zi_doip.conf and README.md "Phase 4" for the
 *          JP6/JP7 jumper and host static-IP setup it requires),
 *          and xenvm (a Xen guest, SoDeV's DomZ, over virtio-net — see
 *          boards/xenvm_doip.conf and xenvm/README.md).
 *
 * THREAD MODEL:
 *   main()        — init -> uds_generated_init -> start the executor and
 *                   DoIP -> return
 *   eds_exec      — the diagnostic executor (EDS platform/zephyr/
 *                   zephyr_exec.c), priority 5: every UDS dispatch, the
 *                   1 ms UDS ticks (S3 session timeout, SecurityAccess
 *                   lockout, periodic scheduling) [EDS#191, EDS#401], a
 *                   pending job's steps, and the ECUReset. After every pass
 *                   it also runs bcm_state_monitor_tick() once per
 *                   millisecond actually elapsed (exec_after_pass(); same
 *                   divisor-based ~100 ms cadence inside that function as
 *                   src/main.c). So the monitor's DTC and calibration
 *                   writes are serialized with the dispatch of
 *                   0x19/0x14/0x31/0x22/0x2E (Zephyr-Reference-ECU#77).
 *   doip_thread   — started via a semaphore (zephyr_lwip.c), runs
 *                   eds_doip_server_run() as the executor's one producer:
 *                   it posts each request and waits for the answer.
 *
 * WATCHDOG SUPERVISION — read this before claiming more than it says:
 *   The hardware watchdog (IWDG, CONFIG_DIAG_WDT_WINDOW_MS) is armed at the
 *   top of main() and fed ONLY from the executor's after-pass hook. A
 *   watchdog fed from one thread supervises that thread, so this covers
 *   exactly:
 *     - the UDS tick path: S3 session timeout, SecurityAccess lockout,
 *       periodic scheduling, bcm_state_monitor_tick() (incl. its NVM
 *       persist — a bank erase is bridged by nvm_store_append_set_wdt());
 *     - every UDS dispatch, because all of them run on the executor: a
 *       dispatch that hangs stops the feed (before, only one that hung
 *       while holding the lock pair did);
 *     - any thread at equal or higher priority than the executor (5)
 *       monopolising the CPU — main (0), the Ethernet RX thread (2), the
 *       cooperative net RX and system work-queue threads — and the kernel
 *       tick itself. doip_thread (7) is lower and is NOT covered this way.
 *   [EDS#399] The DoIP server loop is supervised too, through EDS's
 *   check-in callback: doip_thread checks in on every wake of
 *   eds_doip_server_run() (each accept poll, each recv, each wait for the
 *   executor), and the executor feeds only while the last check-in is less
 *   than DOIP_SUPERVISION_WINDOW_MS old. An idle server with no client still
 *   wakes every DOIP_ACCEPT_POLL_TIMEOUT_MS (5 s) and so never looks hung.
 *   Covered: doip_thread wedged in accept/recv/send or in its wait for the
 *   executor, or having exited. Note what that includes: a tester that
 *   stops reading its socket can block tcp_send() indefinitely, and that now
 *   resets the ECU instead of silently killing DoIP until power-cycled.
 *   NOT covered: the Ethernet link or driver being dead. With no link,
 *   accept still times out and checks in, so that is reported healthy.
 *   Boot before main() is NOT supervised either — see
 *   boards/nucleo_h753zi_doip.conf for why it cannot be on this variant.
 *
 *   [EDS#425] Firmware download (DIAG_SECURE_BOOT_BUILD only). Two flash
 *   calls run on the executor for longer than the window: each chunked-
 *   erase step (one 128 KB sector, up to 4 s per the devicetree) and the
 *   0x37 read-back verify (~34 ms per 256 KiB). For exactly the duration of
 *   each call, a kernel timer in EDS's zephyr_flash_ops.c feeds the
 *   watchdog every 20 ms (EDS#312, EDS#428). So DURING ONE OF THOSE CALLS
 *   neither the tick path nor the DoIP check-in is what keeps the ECU
 *   alive. A hang inside one is bounded by the flash driver's own timeout
 *   (2 x max-erase-time = 8 s per wait), not by the watchdog. Between erase
 *   steps the executor's pass ends, the ticks run, and everything above
 *   applies again. On hardware (the tick-task image that preceded the
 *   executor; not re-measured on this one), RCC_RSR stayed 0 and IWDG1 RLR
 *   0x031F, sampled every 0.5 s through erase, transfer and verify.
 *   After the 0x11 reset, MCUboot's swap runs before main() and is
 *   unsupervised like the rest of boot: measured ~19 s from reset to an
 *   armed IWDG for a 500 KiB image (swap plus the network wait), ~10 s when
 *   MCUboot refuses the image.
 *
 * BUILDING:
 *   west build -b native_sim .    -- -DDIAG_DOIP_ONLY_BUILD=ON
 *   west build -b nucleo_h753zi . -- -DDIAG_DOIP_ONLY_BUILD=ON \
 *       -DEXTRA_CONF_FILE=boards/nucleo_h753zi_doip.conf
 *   # DoIP + secure boot (firmware update over DoIP) — docs/secure-boot.md:
 *   west build -b nucleo_h753zi . -- -DDIAG_DOIP_ONLY_BUILD=ON \
 *       -DDIAG_SECURE_BOOT_BUILD=ON \
 *       "-DEXTRA_CONF_FILE=boards/nucleo_h753zi_doip.conf;boards/nucleo_h753zi_secureboot.conf" \
 *       -DDTC_OVERLAY_FILE=boards/nucleo_h753zi_secureboot.overlay
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
#include "platform_api.h"    /* eds_platform_nvm_flush(), eds_platform_ecu_reset() */

/* --------------------------------------------------------------------------
 * DoIP platform headers
 * -------------------------------------------------------------------------- */
#include "platform_doip.h"   /* eds_doip_platform_start() */
#include "doip_server.h"     /* DOIP_PORT */
#include "zephyr_exec.h"     /* the diagnostic executor (EDS#197) */
#include "zephyr_wdt.h"
#include "nvm_store.h"
#if defined(DIAG_NVM_BACKEND_APPEND)
#include "nvm_store_append.h"   /* nvm_store_append_set_wdt() */
#endif
#if defined(DIAG_SECURE_BOOT_BUILD)
#include "zephyr_flash_ops.h"              /* zephyr_flash_ops_init/_set_wdt() */
#include "zephyr_mcuboot_image_policy.h"   /* zephyr_mcuboot_image_policy_init() */
#include "services.h"
#include <zephyr/dfu/mcuboot.h>            /* boot_is_img_confirmed() et al. */
#endif
#if defined(DIAG_BENCH_SLOW_ROUTINE)
#include "bench_slow_routine.h"            /* [EDS#282] bench slow routine */
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
#include <zephyr/sys/atomic.h>
#include <zephyr/device.h>
#include <zephyr/drivers/flash.h>
#include <zephyr/logging/log.h>
#include <zephyr/storage/flash_map.h>

LOG_MODULE_REGISTER(reference_bcm_doip, LOG_LEVEL_INF);

#include "diag_entropy.h"   /* TRNG callback for SecurityAccess seeds */

/* =============================================================================
 * DoIP ECU configuration — standard xaloqi-tester defaults, same values
 * EDS's own examples/basic_ecu_doip uses, so the free tester's DoipBus
 * default constructor args work unchanged against this ECU too.
 * ============================================================================= */

#define DOIP_ECU_LOGICAL_ADDR   (0xE400U)

/* [EDS#401] Most 1 ms monitor ticks one executor pass will catch up; the cap
 * keeps the catch-up loop bounded. ASSUMPTION: gaps over 1 s don't happen in
 * normal operation. That holds while the 100 ms watchdog window holds,
 * EXCEPT during a firmware download (DIAG_SECURE_BOOT_BUILD): each erase
 * step runs on the executor for one sector erase (~0.83 s measured, up to
 * 4 s) while zephyr_flash_ops.c's timer feeds the watchdog. The executor
 * carries its own UDS ticks over (EDS's eds_elapsed); time beyond 1 s of
 * this file's monitor ticks per step is dropped, as the tick task's was. */
#define DIAG_TICK_CATCHUP_MAX_MS           (1000)

/* Fed only from exec_after_pass() — see "WATCHDOG SUPERVISION" in the header
 * for exactly what that does and does not cover. */
static diag_wdt_t   s_wdt;

/* [EDS#399] DoIP server-loop check-ins, counted on doip_thread and read on
 * the executor. The window is the longest wait EDS bounds between
 * check-ins (the accept poll with no client), plus margin for one dispatch
 * and its response send. */
#define DOIP_SUPERVISION_WINDOW_MS  (DOIP_CHECKIN_MAX_WAIT_MS + 2000U)
static atomic_t     s_doip_checkins;
static atomic_val_t s_doip_seen;        /* executor thread only */
static int64_t      s_doip_checkin_ms;  /* executor thread only */
static int64_t      s_last_tick_ms;     /* executor thread only */

/* [EDS#197] The one producer: DoIP. No periodic TX (0x2A over DoIP answers
 * NRC 0x22 until EDS#546). */
static const uds_exec_producer_cfg_t s_producers[] = {
    { .src = (uint8_t)EDS_DOIP_UDS_SRC, .periodic_tx = false },
};

static void doip_checkin_cb(void)
{
    (void)atomic_inc(&s_doip_checkins);
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
 * Executor bindings [EDS#197] — the monitor tick and the supervision that the
 * UDS tick task used to do [EDS#191]
 * ============================================================================= */

/* An ECUReset, once DoIP has handed the response to the stack and released its
 * slot: persist, let the response leave, reset (EDS#434's sequence). Does not
 * return for a supported type. */
static void exec_ecu_reset(uint8_t reset_type)
{
    (void)eds_platform_nvm_flush();
    (void)k_msleep((int32_t)DOIP_RESET_TX_GRACE_MS);
    (void)eds_platform_ecu_reset(reset_type);
}

/* After every executor pass (1 ms or sooner), on the executor thread. */
static void exec_after_pass(void)
{
    int64_t      now_ms   = k_uptime_get();
    int64_t      elapsed  = now_ms - s_last_tick_ms;
    atomic_val_t doip_now = atomic_get(&s_doip_checkins);

    /* [EDS#401] A pass is not 1 ms: a producer's post wakes the executor
     * early, and a dispatch delays the next one. Run the monitor once per
     * millisecond actually elapsed, as the tick task did, not once per pass. */
    s_last_tick_ms = now_ms;
    if (elapsed > DIAG_TICK_CATCHUP_MAX_MS) {
        elapsed = DIAG_TICK_CATCHUP_MAX_MS;
    }
    for (int64_t i = 0; i < elapsed; i++) {
        bcm_state_monitor_tick();
    }

    /* [EDS#399] Feed only while the DoIP server loop is alive. */
    if (doip_now != s_doip_seen) {
        s_doip_seen       = doip_now;
        s_doip_checkin_ms = now_ms;
    }
    if ((now_ms - s_doip_checkin_ms) < (int64_t)DOIP_SUPERVISION_WINDOW_MS) {
        (void)diag_wdt_feed(&s_wdt);
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
#if defined(DIAG_USE_ENTROPY)
    if (device_is_ready(s_entropy_dev)) {
        (void)uds_security_algo_set_rng_cb(s_trng_cb);
        LOG_INF("[SEC] SecurityAccess seeds from entropy device %s",
                s_entropy_dev->name);
    } else {
        /* Fail closed: an entropy build that silently fell back to the
         * LFSR would repeat its seeds on every boot. */
        LOG_ERR("[SEC] Entropy device %s not ready — refusing to start.",
                s_entropy_dev->name);
        return -1;
    }
#else
    (void)uds_security_algo_set_rng_cb(NULL);
#endif

    /*
     * Arm the watchdog here, explicitly — Zephyr's boot-time arming is off
     * for this variant (boards/nucleo_h753zi_doip.conf). Same position as
     * src/main.c, so the init below runs inside the window too; it takes
     * ~1 ms on hardware, and the executor's first feed follows it.
     *
     * Fail closed, unlike main.c's (void) cast: there, a failed init still
     * leaves Zephyr's boot-armed IWDG running, so the board resets loudly.
     * Here nothing else would arm it, and ignoring the result would mean
     * running unsupervised while appearing supervised (EDS#306's class).
     * On native_sim (CONFIG_WATCHDOG=n) this returns OK in degraded mode.
     * Every `return -1` after this point therefore ends in a watchdog
     * reset on hardware, exactly as in main.c.
     */
    if (diag_wdt_init(&s_wdt) != UDS_STATUS_OK) {
        LOG_ERR("Watchdog arming failed — refusing to run unsupervised.");
        return -1;
    }

#if defined(DIAG_NVM_BACKEND_APPEND)
    /* Bridges the watchdog across the append backend's one bounded bank
     * erase, which can block far past the 100 ms window. Must run before
     * nvm_store_init(). Same call as src/main.c. */
    nvm_store_append_set_wdt(&s_wdt);
#endif

#if defined(DIAG_SECURE_BOOT_BUILD)
    /* [EDS#425] Same bridge for the firmware download: each chunked-erase
     * step (one 128 KB sector, up to 4 s) and the 0x37 read-back verify.
     * Must run before zephyr_flash_ops_init() below. */
    zephyr_flash_ops_set_wdt(&s_wdt);
#endif

    /* Same native_sim-vs-real-hardware split as src/main.c — see that
     * file's identical comment for the FIXED_PARTITION_* rationale. */
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

#if defined(DIAG_BENCH_SLOW_ROUTINE)
    /* [EDS#282] Bench only: RID 0xF0F0 answers 0x78 (bench_slow_routine.h);
     * the DoIP server drives it with uds_server_poll(). */
    LOG_WRN("[BENCH] Slow routine 0xF0F0 registered (response-pending bench).");
    if (bench_slow_routine_register() != UDS_STATUS_OK) {
        LOG_ERR("Bench slow routine registration failed.");
        return -1;
    }
#endif

    (void)uds_periodic_init();
    (void)uds_session_register_change_cb(srv->cfg.session_ctx,
                                          s_on_session_change);

    LOG_INF("UDS stack ready: %u DIDs  %u DTCs",
            (unsigned)GEN_DID_COUNT, (unsigned)GEN_DTC_COUNT);

#if defined(DIAG_SECURE_BOOT_BUILD)
    /* [EDS#425] Firmware download over DoIP. Everything here is non-fatal,
     * as in src/main.c: diagnostics still start, and a missing piece makes
     * 0x34 answer 7F 34 22 instead of accepting an image. */
    if (!boot_is_img_confirmed()) {
        int boot_rc = boot_write_img_confirmed();
        if (boot_rc == 0) {
            LOG_INF("[OTA] New image confirmed — rollback guard cleared.");
        } else {
            LOG_ERR("[OTA] boot_write_img_confirmed() err %d — "
                    "MCUboot will roll back on next reset.", boot_rc);
        }
    }

    /* generated/uds_init.c is the SafeBoot-disabled variant and does not
     * register flash ops, so this entry point does (see
     * Zephyr-Reference-ECU#19 for the CAN one). */
    status = zephyr_flash_ops_init();
    if (status != UDS_STATUS_OK) {
        LOG_ERR("[DFU] Flash ops registration failed: 0x%02X", (unsigned)status);
    }

    status = zephyr_mcuboot_image_policy_init();
    if (status != UDS_STATUS_OK) {
        LOG_ERR("[DFU] Image policy registration failed: 0x%02X — "
                "0x34 RequestDownload will be refused.", (unsigned)status);
    } else {
        LOG_INF("[DFU] Image policy registered (SHA-256 digest verify, "
                "boot_request_upgrade on accept). Authenticity comes "
                "entirely from MCUboot's own RSA-2048-PSS signature check.");
    }
#endif

    /*
     * [EDS#197] Start the executor before the DoIP server, so S3/lockout
     * timing, the monitor tick and the watchdog feed are live from the
     * moment a connection can arrive. The time of the last DoIP check-in
     * starts now, so a DoIP thread that never starts is caught one window
     * after this point.
     */
    s_doip_seen       = atomic_get(&s_doip_checkins);
    s_doip_checkin_ms = k_uptime_get();
    s_last_tick_ms    = s_doip_checkin_ms;
    {
        const zephyr_exec_cfg_t ec = {
            .srv            = srv,
            .producers      = s_producers,
            .producer_count = (uint8_t)ARRAY_SIZE(s_producers),
            .reset          = exec_ecu_reset,
            .after_pass     = exec_after_pass,
        };

        status = zephyr_exec_start(&ec);
        if (status != UDS_STATUS_OK) {
            LOG_ERR("Executor start failed: 0x%02X", (unsigned)status);
            return -1;
        }
    }
    (void)eds_doip_set_executor(zephyr_exec_get(), zephyr_exec_wait_event);
    eds_doip_set_checkin_callback(doip_checkin_cb);   /* [EDS#399] */

    status = eds_doip_platform_start(DOIP_ECU_LOGICAL_ADDR, DOIP_PORT, srv);
    if (status != UDS_STATUS_OK) {
        LOG_ERR("DoIP platform start failed: 0x%02X", (unsigned)status);
        return -1;
    }

    LOG_INF("DoIP server activated — awaiting TCP connections on port %u",
            (unsigned)DOIP_PORT);

    return 0;
}
