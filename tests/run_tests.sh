#!/usr/bin/env bash
# =============================================================================
# Xaloqi Zephyr-Reference-ECU
# tests/run_tests.sh
#
# Builds and runs the host-level unit tests. Plain gcc, no west, no Zephyr,
# no EDS — these tests cover only src/bcm_debounce.c, the one module with
# no such dependency. See that file's header and tests/test_bcm_debounce.c
# for why the rest of src/ is proven by the native_sim CI job instead.
# =============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

gcc -std=c11 -Wall -Wextra -Wshadow -o /tmp/test_bcm_debounce \
    src/bcm_debounce.c tests/test_bcm_debounce.c

/tmp/test_bcm_debounce
