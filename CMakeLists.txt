# =============================================================================
# Xaloqi Zephyr-Reference-ECU
# CMakeLists.txt (project root)
#
# PURPOSE: Wires Xaloqi EDS — pulled in as a west module (see west.yml) — plus
#          this repo's own application sources into a single Zephyr app
#          target, with optional code generation from diagnostics_config.yaml.
#
#          Phase 1 (this phase): native_sim only. The real-hardware board
#          target lands in Phase 2 — see README.md.
#
# USAGE:
#   west build -b native_sim .
#
#   # Skip codegen if generated/ files are already present (the default for
#   # a fresh clone — see "Pre-committed generated C" in README.md):
#   west build -b native_sim . -- -DDIAG_SKIP_CODEGEN=ON
#
# SPDX-License-Identifier: Apache-2.0
# =============================================================================

cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})

project(zephyr_reference_ecu
    VERSION     0.1.0
    LANGUAGES   C
    DESCRIPTION "Xaloqi Zephyr-Reference-ECU — ReferenceBCM"
)

set(CMAKE_C_STANDARD          11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS        OFF)

# ---------------------------------------------------------------------------
# Compiler flags
#
# -Wpedantic and -Wconversion are deliberately absent — Zephyr's own headers
# trip both (C11/GCC extensions, cbprintf sign-conversion noise). Same
# exclusion EDS's own examples make, for the same reason.
# ---------------------------------------------------------------------------
target_compile_options(app PRIVATE
    -Wall
    -Wextra
    -Wshadow
    -Wdouble-promotion
    -Wundef
    -Wno-unused-parameter
    -Wno-sign-conversion
)

# ---------------------------------------------------------------------------
# Xaloqi EDS — resolved via the west module variable Zephyr's module system
# generates from EDS's zephyr/module.yml ("name: xaloqi-eds").
# ---------------------------------------------------------------------------
if(NOT DEFINED ZEPHYR_XALOQI_EDS_MODULE_DIR)
    message(FATAL_ERROR
        "\n"
        "[REF-ECU] ERROR: Xaloqi EDS west module not found.\n"
        "       Expected ZEPHYR_XALOQI_EDS_MODULE_DIR to be set by Zephyr's\n"
        "       module system (see west.yml and EDS's zephyr/module.yml).\n"
        "       Did you run 'west update'?\n"
    )
endif()

set(DIAG_ROOT "${ZEPHYR_XALOQI_EDS_MODULE_DIR}")

set(DIAG_CONFIG_YAML    "${CMAKE_CURRENT_SOURCE_DIR}/diagnostics_config.yaml")
set(DIAG_CODEGEN_SCRIPT "${DIAG_ROOT}/tools/codegen.py")
set(DIAG_GENERATED_DIR  "${CMAKE_CURRENT_SOURCE_DIR}/generated")

# Sentinel: file whose timestamp CMake uses to detect when codegen must re-run.
set(CODEGEN_SENTINEL "${DIAG_GENERATED_DIR}/safety_config.h")

# ---------------------------------------------------------------------------
# Option: disable automatic code generation
#
# Default OFF matches EDS's own examples. A fresh clone of THIS repo should
# flip it ON implicitly via the configure-time check below: codegen needs
# the commercial tools/templates/ this repo does not ship (see
# COMMERCIAL_NOTICE.md) — rather than fail with a confusing Jinja2 error,
# detect the missing templates and fall back to the pre-committed generated/
# tree with a clear message.
# ---------------------------------------------------------------------------
option(DIAG_SKIP_CODEGEN
    "Skip auto-running EDS's tools/codegen.py (use pre-existing generated/ files)"
    OFF
)

# ---------------------------------------------------------------------------
# Option: build the DoIP-only variant (Phase 4) instead of CAN
#
# Selects src/main_doip.c instead of src/main.c, and DoIP transport sources
# instead of ISO-TP/CAN — never both in the same image. See src/main_doip.c's
# own header comment for why this repo does not attempt to run CAN and DoIP
# concurrently (EDS ships no proven architecture for it).
# ---------------------------------------------------------------------------
option(DIAG_DOIP_ONLY_BUILD
    "Build the DoIP transport variant (src/main_doip.c) instead of CAN (src/main.c)"
    OFF
)

# ---------------------------------------------------------------------------
# Option: secure boot (Phase 4) — MCUboot image-policy gate, CAN or DoIP
#
# Adds EDS's flash-ops + MCUboot image-policy sources and the boot-confirm /
# image-policy-registration calls in src/main.c or src/main_doip.c (guarded
# by the DIAG_SECURE_BOOT_BUILD compile definition this sets). Combines with
# DIAG_DOIP_ONLY_BUILD for firmware download over DoIP [EDS#425]. Requires building
# and flashing MCUboot itself separately, and the MCUboot-aware partition
# table in boards/nucleo_h753zi_secureboot.overlay — see README.md "Phase 4".
#
# Scoped to exactly what EDS ships today: MCUboot swap, image-policy gate,
# fail-closed production guard. Firmware authenticity / anti-rollback
# (EDS#319) is open upstream and explicitly excluded.
# ---------------------------------------------------------------------------
option(DIAG_SECURE_BOOT_BUILD
    "Add MCUboot image-policy support (requires MCUboot built and flashed separately)"
    OFF
)

# ---------------------------------------------------------------------------
# Option: SecurityAccess seeds from the zephyr,entropy device (DoIP build)
#
# Registers a TRNG callback in src/main_doip.c or src/main.c instead of EDS's LFSR
# fallback. Used by the xenvm variant (virtio-rng; see xenvm/README.md). Off
# by default so the native_sim and NUCLEO images are unchanged.
# ---------------------------------------------------------------------------
option(DIAG_ENTROPY_SEEDS
    "SecurityAccess seeds from the chosen zephyr,entropy device"
    OFF
)
if(DIAG_ENTROPY_SEEDS)
    target_compile_definitions(app PRIVATE DIAG_ENTROPY_SEEDS=1)
endif()

if(NOT DIAG_SKIP_CODEGEN AND NOT EXISTS "${DIAG_ROOT}/tools/templates")
    message(STATUS
        "[REF-ECU] Commercial tools/templates/ not present (expected — this "
        "is the free tier). Using the pre-committed generated/ tree instead. "
        "See README.md 'Tiers'.")
    set(DIAG_SKIP_CODEGEN ON)
endif()

if(NOT DIAG_SKIP_CODEGEN)

    find_package(Python3 COMPONENTS Interpreter QUIET)

    if(NOT Python3_FOUND)
        message(FATAL_ERROR
            "\n"
            "[REF-ECU] ERROR: Python3 interpreter not found.\n"
            "       Cannot run EDS's tools/codegen.py.\n"
            "       Install Python3 (>= 3.9) with: pip install pyyaml jinja2\n"
            "       Or build with -DDIAG_SKIP_CODEGEN=ON to use the\n"
            "       pre-committed generated/ tree instead.\n"
        )
    endif()

    file(GLOB DIAG_TEMPLATES "${DIAG_ROOT}/tools/templates/*.j2")

    add_custom_command(
        OUTPUT   "${CODEGEN_SENTINEL}"
        COMMAND  "${Python3_EXECUTABLE}"
                 "${DIAG_CODEGEN_SCRIPT}"
                 --config "${DIAG_CONFIG_YAML}"
                 --out    "${DIAG_GENERATED_DIR}"
                 --safety-wrappers
                 --asil-level B
                 --no-manifest
        DEPENDS
            "${DIAG_CONFIG_YAML}"
            "${DIAG_CODEGEN_SCRIPT}"
            ${DIAG_TEMPLATES}
        COMMENT  "[REF-ECU] Generating sources from diagnostics_config.yaml (ASIL-B)..."
        VERBATIM
    )

    add_custom_target(run_codegen
        DEPENDS "${CODEGEN_SENTINEL}"
        COMMENT "[REF-ECU] run_codegen complete."
    )

else()

    message(STATUS
        "[REF-ECU] DIAG_SKIP_CODEGEN=ON — using existing files in ${DIAG_GENERATED_DIR}")

endif()

# ---------------------------------------------------------------------------
# Configure-time check: the one hand-edited "generated/ delta" this repo
# makes (generated/routine_handlers.c's four [APP HOOK] bodies — see that
# file's own banner and src/bcm_state.h) must survive a regeneration.
# ---------------------------------------------------------------------------
if(EXISTS "${DIAG_GENERATED_DIR}/routine_handlers.c")
    file(READ "${DIAG_GENERATED_DIR}/routine_handlers.c" _ROUTINE_HANDLERS_SRC)
    string(FIND "${_ROUTINE_HANDLERS_SRC}" "[APP HOOK]" _APP_HOOK_POS)
    if(_APP_HOOK_POS EQUAL -1)
        message(FATAL_ERROR
            "\n"
            "[REF-ECU] ERROR: generated/routine_handlers.c no longer contains "
            "the [APP HOOK] markers.\n"
            "       If you regenerated this file from diagnostics_config.yaml, "
            "reapply the four bodies documented in src/bcm_state.h, or this "
            "ECU's RoutineControl actuations silently do nothing.\n"
        )
    endif()
endif()

# ---------------------------------------------------------------------------
# Include directories
# ---------------------------------------------------------------------------
target_include_directories(app PRIVATE
    ${DIAG_ROOT}/core
    ${DIAG_ROOT}/core/uds_services
    ${DIAG_ROOT}/transport
    ${DIAG_ROOT}/config
    ${DIAG_ROOT}/platform
    ${DIAG_ROOT}/platform/zephyr
    ${DIAG_GENERATED_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)
if(DIAG_DOIP_ONLY_BUILD)
    target_include_directories(app PRIVATE ${DIAG_ROOT}/transport/doip)
endif()

# ---------------------------------------------------------------------------
# Source files
# ---------------------------------------------------------------------------
include(${DIAG_ROOT}/cmake/eds_service_sources.cmake)

target_sources(app PRIVATE

    # ── This repo's own application layer (Apache-2.0) ────────────────────
    ${CMAKE_CURRENT_SOURCE_DIR}/src/bcm_state.c
    ${CMAKE_CURRENT_SOURCE_DIR}/src/bcm_storage.c
    ${CMAKE_CURRENT_SOURCE_DIR}/src/bcm_debounce.c

    # ── EDS UDS core ────────────────────────────────────────────────────
    ${DIAG_ROOT}/core/uds_server.c
    ${DIAG_ROOT}/core/uds_session.c
    ${DIAG_ROOT}/core/uds_security.c
    ${DIAG_ROOT}/core/uds_safety.c
    ${DIAG_ROOT}/core/uds_security_algo.c
    ${DIAG_ROOT}/core/uds_aes_cmac.c
    ${DIAG_ROOT}/core/uds_access_table.c
    ${DIAG_ROOT}/core/uds_comm_control.c
    ${DIAG_ROOT}/core/uds_session_stats.c
    ${DIAG_ROOT}/core/uds_security_nvm.c
    ${EDS_SERVICE_SRCS}
    ${DIAG_ROOT}/core/uds_transfer_ctx.c
    ${DIAG_ROOT}/platform/uds_flash_ops.c
    ${DIAG_ROOT}/platform/uds_image_policy.c

    # ── EDS configuration databases ─────────────────────────────────────
    ${DIAG_ROOT}/config/did_database.c
    ${DIAG_ROOT}/config/dtc_database.c
    ${DIAG_ROOT}/config/routine_database.c
    ${DIAG_ROOT}/config/dtc_mirror.c

    # ── EDS Zephyr platform abstraction (transport-independent) ──────────
    ${DIAG_ROOT}/platform/zephyr/zephyr_mutex.c
    ${DIAG_ROOT}/platform/zephyr/zephyr_platform_api.c
    # Both entry points arm and feed the watchdog (diag_wdt_init/feed);
    # on native_sim (CONFIG_WATCHDOG=n) it compiles to its degraded no-op.
    ${DIAG_ROOT}/platform/zephyr/zephyr_wdt.c

    # ── Generated sources ────────────────────────────────────────────────
    ${DIAG_GENERATED_DIR}/did_handlers.c
    ${DIAG_GENERATED_DIR}/uds_init.c
    ${DIAG_GENERATED_DIR}/did_safety_wrappers.c
    ${DIAG_GENERATED_DIR}/routine_handlers.c
)

# ---------------------------------------------------------------------------
# Transport-specific entry point and sources — CAN (default) or DoIP
# (DIAG_DOIP_ONLY_BUILD), never both. See src/main_doip.c's header comment
# for why this repo does not attempt both transports in one image.
# ---------------------------------------------------------------------------
if(DIAG_DOIP_ONLY_BUILD)
    target_sources(app PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src/main_doip.c
        ${DIAG_ROOT}/transport/doip/doip_server.c
        ${DIAG_ROOT}/transport/doip/zephyr_lwip.c
        ${DIAG_ROOT}/platform/zephyr/platform_doip.c
    )
    target_compile_definitions(app PRIVATE EDS_DOIP_ONLY_BUILD=1)
else()
    target_sources(app PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src/main.c
        ${DIAG_ROOT}/transport/isotp.c
        ${DIAG_ROOT}/transport/can_transport.c
        ${DIAG_ROOT}/platform/zephyr/zephyr_can.c
        ${DIAG_ROOT}/platform/zephyr/zephyr_port.c
        ${DIAG_ROOT}/platform/zephyr/zephyr_timer.c
    )
endif()

# ---------------------------------------------------------------------------
# Secure boot — either transport [EDS#425]. Same sources and definition for
# CAN and DoIP; placed after the transport sources so the CAN build's link
# order is unchanged.
# ---------------------------------------------------------------------------
if(DIAG_SECURE_BOOT_BUILD)
    target_sources(app PRIVATE
        # Registered with zephyr_flash_ops_init() by both entry points
        # (src/main.c since #19, src/main_doip.c).
        ${DIAG_ROOT}/platform/zephyr/zephyr_flash_ops.c
        # Called from both entry points (zephyr_mcuboot_image_policy_init())
        ${DIAG_ROOT}/platform/zephyr/zephyr_mcuboot_image_policy.c
        # Streaming SHA-256 + MCUboot header/TLV parser — used by the
        # image-policy digest check above
        ${DIAG_ROOT}/platform/uds_sha256.c
        ${DIAG_ROOT}/platform/uds_mcuboot_image.c
    )
    target_compile_definitions(app PRIVATE DIAG_SECURE_BOOT_BUILD=1)
endif()

# ---------------------------------------------------------------------------
# NVM store: platform-conditional source selection (same pattern as EDS's
# own examples/safeboot_ecu/CMakeLists.txt, the reference for this exact
# board).
#
#   native_sim      — nvm_store_mock.c, RAM-backed, no real flash to resolve.
#   nucleo_h753zi   — nvm_store_append.c, the append-only backend EDS#304
#                     introduced for STM32H7 boards: their uniform 128 KB
#                     erase sectors exceed nvs_fs.sector_size's uint16_t
#                     range, so nvm_store.c's classic NVS backend cannot
#                     mount this partition at all on this part.
#
# Exactly one must be compiled per build; any two would produce duplicate-
# symbol linker errors (all three define the same nvm_store_* API).
# ---------------------------------------------------------------------------
if(CONFIG_BOARD_NATIVE_SIM)
    target_sources(app PRIVATE ${DIAG_ROOT}/platform/zephyr/nvm_store_mock.c)
elseif(CONFIG_BOARD_NUCLEO_H753ZI)
    target_sources(app PRIVATE ${DIAG_ROOT}/platform/zephyr/nvm_store_append.c)
    target_compile_definitions(app PRIVATE DIAG_NVM_BACKEND_APPEND=1)
else()
    target_sources(app PRIVATE ${DIAG_ROOT}/platform/zephyr/nvm_store.c)
endif()

if(NOT DIAG_SKIP_CODEGEN AND TARGET run_codegen)
    add_dependencies(app run_codegen)
endif()

# Required for the build to compile: _Static_assert in uds_types.h fires at
# translation-unit level whenever sizeof(uds_msg_buf_t) > EDS_MSG_BUF_MAX_STACK_BYTES.
target_compile_definitions(app PRIVATE EDS_MSG_BUF_MAX_STACK_BYTES=8192)
