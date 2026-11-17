#!/bin/bash
# Test for Issue #47: Weekend/holiday grace period for repo commit staleness
# Verifies that repos using default thresholds skip weekends when counting staleness

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #47: Weekend grace period for repo staleness"
echo "=========================================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() {
    echo "  PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail_test() {
    echo "  FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Helper: run JS test and check result
run_and_check() {
    local test_name="$1"
    local js_code="$2"
    local output
    output=$(run_js_test "$js_code" 2>&1) || true
    local result
    result=$(echo "$output" | grep "^TEST_RESULT:${test_name}:" | head -1)
    if [[ "$result" == *":PASS:"* ]]; then
        local detail
        detail=$(echo "$result" | cut -d: -f4-)
        pass_test "$test_name: $detail"
    else
        local detail
        detail=$(echo "$result" | cut -d: -f4-)
        if [ -z "$detail" ]; then
            detail="no output (full: $output)"
        fi
        fail_test "$test_name: $detail"
    fi
}

# Timestamps (all midnight UTC, verified correct):
# Mon 2026-03-02 = 1772409600
# Tue 2026-03-03 = 1772496000
# Wed 2026-03-04 = 1772582400
# Thu 2026-03-05 = 1772668800
# Fri 2026-03-06 = 1772755200
# Sat 2026-03-07 = 1772841600
# Sun 2026-03-08 = 1772928000
# Mon 2026-03-09 = 1773014400
# Fri 2026-03-13 = 1773360000

# ============================================================
# Test 1: countBusinessDays — pure weekday counting
# ============================================================
echo "Test 1: countBusinessDays function..."

# Monday to Wednesday = 2 business days (Tue + Wed)
run_and_check "bdays-mon-to-wed" '
    const mon = 1772409600; // Mon 2026-03-02 00:00 UTC
    const wed = 1772582400; // Wed 2026-03-04 00:00 UTC
    const days = countBusinessDays(mon, wed);
    if (days === 2) {
        console.log("TEST_RESULT:bdays-mon-to-wed:PASS:Mon to Wed = 2 business days");
    } else {
        console.log("TEST_RESULT:bdays-mon-to-wed:FAIL:expected 2, got " + days);
    }
'

# Friday to Monday = 1 business day (Mon; Sat+Sun skipped)
run_and_check "bdays-fri-to-mon" '
    const fri = 1772755200; // Fri 2026-03-06 00:00 UTC
    const mon = 1773014400; // Mon 2026-03-09 00:00 UTC
    const days = countBusinessDays(fri, mon);
    if (days === 1) {
        console.log("TEST_RESULT:bdays-fri-to-mon:PASS:Fri to Mon = 1 business day");
    } else {
        console.log("TEST_RESULT:bdays-fri-to-mon:FAIL:expected 1, got " + days);
    }
'

# Friday to next Friday = 5 business days (Mon-Fri)
run_and_check "bdays-full-week" '
    const fri1 = 1772755200; // Fri 2026-03-06 00:00 UTC
    const fri2 = 1773360000; // Fri 2026-03-13 00:00 UTC
    const days = countBusinessDays(fri1, fri2);
    if (days === 5) {
        console.log("TEST_RESULT:bdays-full-week:PASS:Fri to next Fri = 5 business days");
    } else {
        console.log("TEST_RESULT:bdays-full-week:FAIL:expected 5, got " + days);
    }
'

# Saturday to Monday = 0 business days (Sun skipped, Mon is toMidnight itself)
run_and_check "bdays-sat-to-mon" '
    const sat = 1772841600; // Sat 2026-03-07 00:00 UTC
    const mon = 1773014400; // Mon 2026-03-09 00:00 UTC
    const days = countBusinessDays(sat, mon);
    if (days === 1) {
        console.log("TEST_RESULT:bdays-sat-to-mon:PASS:Sat to Mon = 1 business day (Mon)");
    } else {
        console.log("TEST_RESULT:bdays-sat-to-mon:FAIL:expected 1, got " + days);
    }
'

# Same timestamp = 0 business days
run_and_check "bdays-same-ts" '
    const ts = 1772409600;
    const days = countBusinessDays(ts, ts);
    if (days === 0) {
        console.log("TEST_RESULT:bdays-same-ts:PASS:same timestamp = 0 business days");
    } else {
        console.log("TEST_RESULT:bdays-same-ts:FAIL:expected 0, got " + days);
    }
'

# ============================================================
# Test 2: getRepoStatus — default repos use business days
# ============================================================
echo ""
echo "Test 2: getRepoStatus with default thresholds skips weekends..."

# Repo committed on Friday, checked on Monday (3 calendar days, 1 business day)
# Should be healthy with defaults (1 business day warning / 2 business days error)
run_and_check "default-over-weekend-healthy" '
    const fridayNoon = 1772755200 + 43200; // Fri 2026-03-06 12:00 UTC
    const mondayNoon = 1773014400 + 43200; // Mon 2026-03-09 12:00 UTC

    const repo = { name: "TestRepo", last_commit_ts: fridayNoon };
    const status = getRepoStatus(repo, mondayNoon);
    if (status === "healthy") {
        console.log("TEST_RESULT:default-over-weekend-healthy:PASS:Friday commit healthy on Monday");
    } else {
        console.log("TEST_RESULT:default-over-weekend-healthy:FAIL:expected healthy, got " + status);
    }
'

# Repo committed on Thursday, checked on Monday (4 calendar days, 2 business days)
# Should be warning with defaults (>1 business day)
run_and_check "default-thu-to-mon-warning" '
    const thuNoon = 1772668800 + 43200; // Thu 2026-03-05 12:00 UTC
    const mondayNoon = 1773014400 + 43200; // Mon 2026-03-09 12:00 UTC

    const repo = { name: "TestRepo", last_commit_ts: thuNoon };
    const status = getRepoStatus(repo, mondayNoon);
    if (status === "warning") {
        console.log("TEST_RESULT:default-thu-to-mon-warning:PASS:Thursday commit warning on Monday");
    } else {
        console.log("TEST_RESULT:default-thu-to-mon-warning:FAIL:expected warning, got " + status);
    }
'

# Repo committed on Wednesday, checked on Monday (5 calendar days, 3 business days)
# Should be error with defaults (>2 business days)
run_and_check "default-wed-to-mon-error" '
    const wedNoon = 1772582400 + 43200; // Wed 2026-03-04 12:00 UTC
    const mondayNoon = 1773014400 + 43200; // Mon 2026-03-09 12:00 UTC

    const repo = { name: "TestRepo", last_commit_ts: wedNoon };
    const status = getRepoStatus(repo, mondayNoon);
    if (status === "error") {
        console.log("TEST_RESULT:default-wed-to-mon-error:PASS:Wednesday commit error on Monday");
    } else {
        console.log("TEST_RESULT:default-wed-to-mon-error:FAIL:expected error, got " + status);
    }
'

# ============================================================
# Test 3: Explicit thresholds still use calendar days
# ============================================================
echo ""
echo "Test 3: Repos with explicit thresholds use calendar days..."

# Repo with explicit thresholds committed on Friday, checked on Monday
# 3 calendar days > 2 day error threshold = error (calendar days, not business days)
run_and_check "explicit-calendar-days" '
    const fridayNoon = 1772755200 + 43200; // Fri 2026-03-06 12:00 UTC
    const mondayNoon = 1773014400 + 43200; // Mon 2026-03-09 12:00 UTC

    const repo = { name: "ExplicitRepo", last_commit_ts: fridayNoon, warning_days: 1, error_days: 2 };
    const status = getRepoStatus(repo, mondayNoon);
    if (status === "error") {
        console.log("TEST_RESULT:explicit-calendar-days:PASS:explicit thresholds use calendar days");
    } else {
        console.log("TEST_RESULT:explicit-calendar-days:FAIL:expected error, got " + status);
    }
'

# Repo with explicit wide thresholds committed on Friday, checked on Monday
# 3 calendar days < 5 day warning = healthy
run_and_check "explicit-wide-threshold" '
    const fridayNoon = 1772755200 + 43200; // Fri 2026-03-06 12:00 UTC
    const mondayNoon = 1773014400 + 43200; // Mon 2026-03-09 12:00 UTC

    const repo = { name: "WideRepo", last_commit_ts: fridayNoon, warning_days: 5, error_days: 10 };
    const status = getRepoStatus(repo, mondayNoon);
    if (status === "healthy") {
        console.log("TEST_RESULT:explicit-wide-threshold:PASS:explicit wide thresholds still healthy");
    } else {
        console.log("TEST_RESULT:explicit-wide-threshold:FAIL:expected healthy, got " + status);
    }
'

# ============================================================
# Test 4: Edge cases
# ============================================================
echo ""
echo "Test 4: Edge cases..."

# No timestamp should still return error
run_and_check "no-timestamp-error" '
    const repo = { name: "NoTs" };
    const status = getRepoStatus(repo);
    if (status === "error") {
        console.log("TEST_RESULT:no-timestamp-error:PASS:no timestamp returns error");
    } else {
        console.log("TEST_RESULT:no-timestamp-error:FAIL:expected error, got " + status);
    }
'

# Weekday commit checked same weekday should be healthy
run_and_check "same-day-healthy" '
    const morning = 1773014400 + 36000; // Mon 2026-03-09 10:00 UTC
    const afternoon = 1773014400 + 50400; // Mon 2026-03-09 14:00 UTC

    const repo = { name: "SameDay", last_commit_ts: morning };
    const status = getRepoStatus(repo, afternoon);
    if (status === "healthy") {
        console.log("TEST_RESULT:same-day-healthy:PASS:same day commit is healthy");
    } else {
        console.log("TEST_RESULT:same-day-healthy:FAIL:expected healthy, got " + status);
    }
'

# Only warning_days set (no error_days) — should use calendar days since threshold is explicit
run_and_check "partial-explicit-warning-only" '
    const fridayNoon = 1772755200 + 43200; // Fri 2026-03-06 12:00 UTC
    const mondayNoon = 1773014400 + 43200; // Mon 2026-03-09 12:00 UTC

    // warning_days is explicit — uses calendar days
    const repo = { name: "PartialRepo", last_commit_ts: fridayNoon, warning_days: 1.5 };
    const status = getRepoStatus(repo, mondayNoon);
    // 3 calendar days > 1.5 warning, > 2 error (default) = error
    if (status === "error") {
        console.log("TEST_RESULT:partial-explicit-warning-only:PASS:partial explicit uses calendar days");
    } else {
        console.log("TEST_RESULT:partial-explicit-warning-only:FAIL:expected error, got " + status);
    }
'

# Two-week span: Mon to Mon (10 business days)
run_and_check "bdays-two-weeks" '
    const mon1 = 1772409600; // Mon 2026-03-02 00:00 UTC
    const mon2 = 1773014400 + 604800; // Mon 2026-03-16 00:00 UTC
    const days = countBusinessDays(mon1, mon2);
    if (days === 10) {
        console.log("TEST_RESULT:bdays-two-weeks:PASS:2 weeks = 10 business days");
    } else {
        console.log("TEST_RESULT:bdays-two-weeks:FAIL:expected 10, got " + days);
    }
'

echo ""
echo "=========================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
