#!/bin/bash
# Test for Issue #67: Weekend-aware health checks for repos with explicit thresholds
# Verifies that repos with business_days_only flag skip weekends even with custom thresholds

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #67: Weekend-aware repos (business_days_only flag)"
echo "================================================================"
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
# Test 1: FX-like repo — Friday update, Monday check should be healthy
# ============================================================
echo "Test 1: FX-like repo with business_days_only over weekend..."

# FX: warning_days: 1.5, error_days: 4, business_days_only: true
# Updated Friday noon, checked Monday morning — only 1 business day elapsed
# Without business_days_only: 3 calendar days > 1.5 warning = warning/error
# With business_days_only: 1 business day < 1.5 = healthy
run_and_check "fx-weekend-healthy" '
    const fridayNoon = 1772755200 + 43200; // Fri 2026-03-06 12:00 UTC
    const mondayMorn = 1773014400 + 36000; // Mon 2026-03-09 10:00 UTC

    const repo = {
        name: "FX",
        last_commit_ts: fridayNoon,
        warning_days: 1.5,
        error_days: 4,
        business_days_only: true
    };
    const status = getRepoStatus(repo, mondayMorn);
    if (status === "healthy") {
        console.log("TEST_RESULT:fx-weekend-healthy:PASS:FX healthy on Monday after Friday update");
    } else {
        console.log("TEST_RESULT:fx-weekend-healthy:FAIL:expected healthy, got " + status);
    }
'

# ============================================================
# Test 2: business_days_only repo warns after enough business days
# ============================================================
echo ""
echo "Test 2: business_days_only repo warns after threshold business days..."

# FX updated Friday, checked Wednesday — 3 business days (Mon, Tue, Wed) > 1.5 warning
run_and_check "fx-midweek-warning" '
    const fridayNoon = 1772755200 + 43200; // Fri 2026-03-06 12:00 UTC
    const wedNoon = 1772582400 + 43200 + 604800; // Wed 2026-03-11 12:00 UTC

    const repo = {
        name: "FX",
        last_commit_ts: fridayNoon,
        warning_days: 1.5,
        error_days: 4,
        business_days_only: true
    };
    const status = getRepoStatus(repo, wedNoon);
    if (status === "warning") {
        console.log("TEST_RESULT:fx-midweek-warning:PASS:FX warns after 3 business days > 1.5 threshold");
    } else {
        console.log("TEST_RESULT:fx-midweek-warning:FAIL:expected warning, got " + status);
    }
'

# ============================================================
# Test 3: business_days_only repo errors after error threshold
# ============================================================
echo ""
echo "Test 3: business_days_only repo errors after error threshold..."

# FX updated Mon Mar 2, checked next Wed Mar 11 — 7 business days > 4 error
run_and_check "fx-error-threshold" '
    const monNoon = 1772409600 + 43200; // Mon 2026-03-02 12:00 UTC
    const wedNoon = 1772582400 + 43200 + 604800; // Wed 2026-03-11 12:00 UTC

    const repo = {
        name: "FX",
        last_commit_ts: monNoon,
        warning_days: 1.5,
        error_days: 4,
        business_days_only: true
    };
    const status = getRepoStatus(repo, wedNoon);
    if (status === "error") {
        console.log("TEST_RESULT:fx-error-threshold:PASS:FX errors after 7 business days > 4 threshold");
    } else {
        console.log("TEST_RESULT:fx-error-threshold:FAIL:expected error, got " + status);
    }
'

# ============================================================
# Test 4: Without business_days_only, explicit thresholds still use calendar days
# ============================================================
echo ""
echo "Test 4: Backward compatibility — no flag uses calendar days..."

# Same FX-like thresholds but without business_days_only
# Friday to Monday = 3 calendar days > 1.5 warning, < 4 error = warning
run_and_check "no-flag-calendar-days" '
    const fridayNoon = 1772755200 + 43200; // Fri 2026-03-06 12:00 UTC
    const mondayMorn = 1773014400 + 36000; // Mon 2026-03-09 10:00 UTC

    const repo = {
        name: "NoFlag",
        last_commit_ts: fridayNoon,
        warning_days: 1.5,
        error_days: 4
    };
    const status = getRepoStatus(repo, mondayMorn);
    if (status === "warning") {
        console.log("TEST_RESULT:no-flag-calendar-days:PASS:without flag, calendar days used (warning)");
    } else {
        console.log("TEST_RESULT:no-flag-calendar-days:FAIL:expected warning, got " + status);
    }
'

# ============================================================
# Test 5: business_days_only with only warning_days set (error_days defaults to 2)
# ============================================================
echo ""
echo "Test 5: business_days_only with partial explicit thresholds..."

# warning_days: 1.5 set, error_days defaults to 2
# Friday to Monday = 1 business day < 1.5 warning = healthy
run_and_check "partial-bdays-healthy" '
    const fridayNoon = 1772755200 + 43200; // Fri 2026-03-06 12:00 UTC
    const mondayMorn = 1773014400 + 36000; // Mon 2026-03-09 10:00 UTC

    const repo = {
        name: "PartialBDays",
        last_commit_ts: fridayNoon,
        warning_days: 1.5,
        business_days_only: true
    };
    const status = getRepoStatus(repo, mondayMorn);
    if (status === "healthy") {
        console.log("TEST_RESULT:partial-bdays-healthy:PASS:partial explicit with business_days_only stays healthy");
    } else {
        console.log("TEST_RESULT:partial-bdays-healthy:FAIL:expected healthy, got " + status);
    }
'

# ============================================================
# Test 6: business_days_only false is same as not set
# ============================================================
echo ""
echo "Test 6: business_days_only: false treated same as not set..."

run_and_check "bdays-false-calendar" '
    const fridayNoon = 1772755200 + 43200; // Fri 2026-03-06 12:00 UTC
    const mondayMorn = 1773014400 + 36000; // Mon 2026-03-09 10:00 UTC

    const repo = {
        name: "BDaysFalse",
        last_commit_ts: fridayNoon,
        warning_days: 1.5,
        error_days: 4,
        business_days_only: false
    };
    const status = getRepoStatus(repo, mondayMorn);
    if (status === "warning") {
        console.log("TEST_RESULT:bdays-false-calendar:PASS:business_days_only false uses calendar days");
    } else {
        console.log("TEST_RESULT:bdays-false-calendar:FAIL:expected warning, got " + status);
    }
'

# ============================================================
# Test 7: Same-day check should be healthy regardless of flag
# ============================================================
echo ""
echo "Test 7: Same-day check is healthy with business_days_only..."

run_and_check "bdays-same-day" '
    const morning = 1773014400 + 36000; // Mon 2026-03-09 10:00 UTC
    const afternoon = 1773014400 + 50400; // Mon 2026-03-09 14:00 UTC

    const repo = {
        name: "SameDay",
        last_commit_ts: morning,
        warning_days: 1.5,
        error_days: 4,
        business_days_only: true
    };
    const status = getRepoStatus(repo, afternoon);
    if (status === "healthy") {
        console.log("TEST_RESULT:bdays-same-day:PASS:same day is healthy");
    } else {
        console.log("TEST_RESULT:bdays-same-day:FAIL:expected healthy, got " + status);
    }
'

# ============================================================
# Test 8: Saturday check — last update Friday, should be healthy
# ============================================================
echo ""
echo "Test 8: Weekend check on Saturday after Friday update..."

run_and_check "bdays-saturday-check" '
    const fridayNoon = 1772755200 + 43200; // Fri 2026-03-06 12:00 UTC
    const saturdayNoon = 1772841600 + 43200; // Sat 2026-03-07 12:00 UTC

    const repo = {
        name: "SatCheck",
        last_commit_ts: fridayNoon,
        warning_days: 1.5,
        error_days: 4,
        business_days_only: true
    };
    const status = getRepoStatus(repo, saturdayNoon);
    if (status === "healthy") {
        console.log("TEST_RESULT:bdays-saturday-check:PASS:Saturday check after Friday update is healthy");
    } else {
        console.log("TEST_RESULT:bdays-saturday-check:FAIL:expected healthy, got " + status);
    }
'

echo ""
echo "================================================================"
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
