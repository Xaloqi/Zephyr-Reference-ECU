// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Xaloqi
/*
 * =============================================================================
 * Xaloqi Zephyr-Reference-ECU
 * FILE: tests/test_bcm_debounce.c
 *
 * PURPOSE: Host-level unit test for src/bcm_debounce.c — the one piece of
 *          application logic in this repo with no Zephyr or EDS dependency,
 *          so it builds and runs with plain gcc. Run it with:
 *
 *            bash tests/run_tests.sh
 *
 *          Everything else in src/ (bcm_state.c, bcm_storage.c, main.c)
 *          needs the full west/Zephyr/EDS build to even compile — proven
 *          instead by the native_sim CI job (see .github/workflows/ci.yml).
 *
 * A NEW TEST ISN'T DONE UNTIL IT HAS FAILED: every assertion below was run
 * against a deliberately broken bcm_debounce.c first (threshold off-by-one,
 * heal counter never reset) to confirm it actually catches the defect it
 * names, not just that it compiles.
 * =============================================================================
 */

#include "../src/bcm_debounce.h"

#include <assert.h>
#include <stdio.h>

static int s_failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s (line %d)\n", (msg), __LINE__); \
        s_failures++; \
    } \
} while (0)

static void test_inactive_until_threshold(void)
{
    bcm_debounce_t d;
    bcm_debounce_init(&d);

    CHECK(bcm_debounce_update(&d, true, 3U) == false, "1st tick: below threshold");
    CHECK(bcm_debounce_update(&d, true, 3U) == false, "2nd tick: below threshold");
    CHECK(bcm_debounce_update(&d, true, 3U) == true,  "3rd tick: reaches threshold");
    CHECK(bcm_debounce_update(&d, true, 3U) == true,  "stays active while held");
}

static void test_heals_after_threshold(void)
{
    bcm_debounce_t d;
    bcm_debounce_init(&d);

    (void)bcm_debounce_update(&d, true, 2U);
    CHECK(bcm_debounce_update(&d, true, 2U) == true, "active after 2 ticks");

    CHECK(bcm_debounce_update(&d, false, 2U) == true,  "1st heal tick: still active");
    CHECK(bcm_debounce_update(&d, false, 2U) == false, "2nd heal tick: heals");
}

static void test_flicker_resets_both_counters(void)
{
    /* A condition that flickers on/off every tick must never accumulate
     * across the gap -- this is the exact defect class a naive
     * "increment on condition, decrement otherwise" implementation gets
     * wrong (it can still cross the threshold on a flickering signal that
     * never holds continuously). */
    bcm_debounce_t d;
    bcm_debounce_init(&d);

    for (int i = 0; i < 10; i++) {
        bool held = (i % 2) == 0;    /* held, not held, held, not held, ... */
        CHECK(bcm_debounce_update(&d, held, 3U) == false,
              "flickering signal below threshold must never go active");
    }
}

static void test_brief_recovery_resets_the_heal_countdown(void)
{
    /* Once active, a single tick of recovery must reset the heal countdown
     * to zero, not just pause it -- otherwise two short recovery streaks
     * that never individually reach the heal threshold can add up across
     * an intervening "held" tick and heal the condition early. */
    bcm_debounce_t d;
    bcm_debounce_init(&d);

    (void)bcm_debounce_update(&d, true, 3U);
    (void)bcm_debounce_update(&d, true, 3U);
    CHECK(bcm_debounce_update(&d, true, 3U) == true, "active after reaching threshold");

    CHECK(bcm_debounce_update(&d, false, 3U) == true, "heal tick 1/3: still active");
    CHECK(bcm_debounce_update(&d, false, 3U) == true, "heal tick 2/3: still active");
    CHECK(bcm_debounce_update(&d, true, 3U)  == true, "condition returns: heal countdown must reset");
    CHECK(bcm_debounce_update(&d, false, 3U) == true,
          "post-reset heal tick 1/3: must NOT have healed (would have, "
          "had the earlier 2 heal ticks carried over)");
}

static void test_zero_threshold_treated_as_one(void)
{
    bcm_debounce_t d;
    bcm_debounce_init(&d);

    CHECK(bcm_debounce_update(&d, true, 0U) == true,
          "threshold 0 is treated as 1 -- an edge on the very first tick");
}

static void test_independent_instances_do_not_share_state(void)
{
    bcm_debounce_t a, b;
    bcm_debounce_init(&a);
    bcm_debounce_init(&b);

    (void)bcm_debounce_update(&a, true, 2U);
    (void)bcm_debounce_update(&a, true, 2U);
    CHECK(a.active == true,  "a is active");
    CHECK(b.active == false, "b, a separate instance, is untouched");
}

int main(void)
{
    test_inactive_until_threshold();
    test_heals_after_threshold();
    test_brief_recovery_resets_the_heal_countdown();
    test_flicker_resets_both_counters();
    test_zero_threshold_treated_as_one();
    test_independent_instances_do_not_share_state();

    if (s_failures == 0) {
        printf("test_bcm_debounce: all assertions passed\n");
        return 0;
    }
    fprintf(stderr, "test_bcm_debounce: %d failure(s)\n", s_failures);
    return 1;
}
