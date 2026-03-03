#!/bin/bash
# Test for Issue #47: Weekend/holiday grace period for repo commit staleness
# Verifies that repos with default thresholds do not trigger warnings over weekends,
# while repos with explicitly configured thresholds continue to work as before.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #47: Weekend/holiday grace period"
echo "=============================================="
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

OUTPUT=$(run_js_test '
// Helper: create a unix timestamp for a specific date/time (UTC)
function makeTs(year, month, day, hour, minute) {
    return Math.floor(new Date(Date.UTC(year, month - 1, day, hour, minute, 0)).getTime() / 1000);
}

// =====================================================
// Test 1: countWeekendDays counts Saturday and Sunday
// Friday 2026-01-02 to Monday 2026-01-05 spans one weekend (Sat+Sun)
// =====================================================
{
    const fri = makeTs(2026, 1, 2, 12, 0);
    const mon = makeTs(2026, 1, 5, 12, 0);
    const result = countWeekendDays(fri, mon);
    if (result === 2) {
        console.log("TEST_RESULT:count-weekend-basic:PASS:counted 2 weekend days (Sat+Sun)");
    } else {
        console.log("TEST_RESULT:count-weekend-basic:FAIL:expected 2, got " + result);
    }
}

// =====================================================
// Test 2: countWeekendDays returns 0 for weekday-only span
// Monday to Wednesday = 0 weekend days
// =====================================================
{
    const mon = makeTs(2026, 1, 5, 12, 0);
    const wed = makeTs(2026, 1, 7, 12, 0);
    const result = countWeekendDays(mon, wed);
    if (result === 0) {
        console.log("TEST_RESULT:count-weekend-none:PASS:0 weekend days in weekday span");
    } else {
        console.log("TEST_RESULT:count-weekend-none:FAIL:expected 0, got " + result);
    }
}

// =====================================================
// Test 3: countWeekendDays counts multiple weekends
// Friday 2026-01-02 to Monday 2026-01-12 spans two weekends (4 weekend days)
// =====================================================
{
    const fri = makeTs(2026, 1, 2, 12, 0);
    const mon = makeTs(2026, 1, 12, 12, 0);
    const result = countWeekendDays(fri, mon);
    if (result === 4) {
        console.log("TEST_RESULT:count-weekend-multiple:PASS:counted 4 weekend days across 2 weekends");
    } else {
        console.log("TEST_RESULT:count-weekend-multiple:FAIL:expected 4, got " + result);
    }
}

// =====================================================
// Test 4: Default repo - commit on Friday, checked Monday = healthy
// Last commit Friday 17:00, checked Monday 09:00 = ~62 hours elapsed
// With 2 weekend days subtracted: ~62 - 48 = ~14 hours effective
// Should be healthy (under 1-day default warning threshold)
// =====================================================
{
    const fridayCommit = makeTs(2026, 1, 2, 17, 0);
    const mondayNow = makeTs(2026, 1, 5, 9, 0);
    const repo = { name: "TestRepo", last_commit_ts: fridayCommit };
    const status = getRepoStatus(repo, mondayNow);
    if (status === "healthy") {
        console.log("TEST_RESULT:default-friday-monday-healthy:PASS:Friday commit healthy on Monday");
    } else {
        console.log("TEST_RESULT:default-friday-monday-healthy:FAIL:expected healthy, got " + status);
    }
}

// =====================================================
// Test 5: Default repo - commit on Wednesday, checked Monday = warning/error
// Last commit Wednesday 17:00, checked Monday 09:00 = ~5 days elapsed
// With 2 weekend days subtracted: ~3 effective days
// Should NOT be healthy (over 1-day default warning)
// =====================================================
{
    const wedCommit = makeTs(2025, 12, 31, 17, 0);
    const mondayNow = makeTs(2026, 1, 5, 9, 0);
    const repo = { name: "TestRepo", last_commit_ts: wedCommit };
    const status = getRepoStatus(repo, mondayNow);
    if (status !== "healthy") {
        console.log("TEST_RESULT:default-wed-monday-not-healthy:PASS:Wednesday commit not healthy on Monday (got " + status + ")");
    } else {
        console.log("TEST_RESULT:default-wed-monday-not-healthy:FAIL:expected warning or error, got healthy");
    }
}

// =====================================================
// Test 6: Explicit thresholds are unaffected by weekend grace
// Repo with warning_days=1, error_days=2 should use calendar days (no weekend subtraction)
// Friday commit, checked Monday (~2.7 days) should be error
// =====================================================
{
    const fridayCommit = makeTs(2026, 1, 2, 17, 0);
    const mondayNow = makeTs(2026, 1, 5, 9, 0);
    const repo = { name: "ExplicitRepo", last_commit_ts: fridayCommit, warning_days: 1, error_days: 2 };
    const status = getRepoStatus(repo, mondayNow);
    if (status === "error") {
        console.log("TEST_RESULT:explicit-no-grace:PASS:explicit threshold repo uses calendar days");
    } else {
        console.log("TEST_RESULT:explicit-no-grace:FAIL:expected error for explicit repo, got " + status);
    }
}

// =====================================================
// Test 7: Default repo - commit on Thursday, checked Saturday = healthy
// Last commit Thursday 17:00, checked Saturday 09:00 = ~40 hours
// Saturday is a weekend day but only 1 weekend day passed so far
// With 1 weekend day subtracted: ~16 hours effective
// Should be healthy
// =====================================================
{
    const thuCommit = makeTs(2026, 1, 1, 17, 0);
    const satNow = makeTs(2026, 1, 3, 9, 0);
    const repo = { name: "TestRepo", last_commit_ts: thuCommit };
    const status = getRepoStatus(repo, satNow);
    if (status === "healthy") {
        console.log("TEST_RESULT:default-thu-sat-healthy:PASS:Thursday commit healthy on Saturday");
    } else {
        console.log("TEST_RESULT:default-thu-sat-healthy:FAIL:expected healthy, got " + status);
    }
}

// =====================================================
// Test 8: THRESHOLDS has REPO_DEFAULT_WARNING_DAYS and REPO_DEFAULT_ERROR_DAYS
// =====================================================
{
    const hasWarning = THRESHOLDS.REPO_DEFAULT_WARNING_DAYS !== undefined;
    const hasError = THRESHOLDS.REPO_DEFAULT_ERROR_DAYS !== undefined;
    if (hasWarning && hasError) {
        console.log("TEST_RESULT:thresholds-repo-defaults:PASS:REPO_DEFAULT_WARNING_DAYS=" + THRESHOLDS.REPO_DEFAULT_WARNING_DAYS + " REPO_DEFAULT_ERROR_DAYS=" + THRESHOLDS.REPO_DEFAULT_ERROR_DAYS);
    } else {
        console.log("TEST_RESULT:thresholds-repo-defaults:FAIL:missing repo default threshold constants");
    }
}

// =====================================================
// Test 9: Default repo - commit on Monday, checked Wednesday = warning
// Last commit Monday 09:00, checked Wednesday 12:00 = ~51 hours = ~2.1 days
// No weekend days in between, so effective days = ~2.1
// Should be error (over 2-day default error threshold)
// =====================================================
{
    const monCommit = makeTs(2026, 1, 5, 9, 0);
    const wedNow = makeTs(2026, 1, 7, 12, 0);
    const repo = { name: "TestRepo", last_commit_ts: monCommit };
    const status = getRepoStatus(repo, wedNow);
    if (status === "error") {
        console.log("TEST_RESULT:default-weekday-error:PASS:2+ days on weekdays triggers error");
    } else {
        console.log("TEST_RESULT:default-weekday-error:FAIL:expected error, got " + status);
    }
}

// =====================================================
// Test 10: Default repo - commit on Friday morning, checked Sunday evening
// Last commit Friday 09:00, checked Sunday 21:00 = ~60 hours
// With 2 weekend days subtracted: ~60 - 48 = ~12 hours effective
// Should be healthy
// =====================================================
{
    const friCommit = makeTs(2026, 1, 2, 9, 0);
    const sunNow = makeTs(2026, 1, 4, 21, 0);
    const repo = { name: "TestRepo", last_commit_ts: friCommit };
    const status = getRepoStatus(repo, sunNow);
    if (status === "healthy") {
        console.log("TEST_RESULT:default-fri-sun-healthy:PASS:Friday commit healthy on Sunday");
    } else {
        console.log("TEST_RESULT:default-fri-sun-healthy:FAIL:expected healthy, got " + status);
    }
}

// =====================================================
// Test 11: getRepoStatus without nowTs uses current time (backwards compat)
// Recent commit should be healthy regardless
// =====================================================
{
    const now = Math.floor(Date.now() / 1000);
    const repo = { name: "TestRepo", last_commit_ts: now - 3600 }; // 1 hour ago
    const status = getRepoStatus(repo);
    if (status === "healthy") {
        console.log("TEST_RESULT:no-nowts-param:PASS:getRepoStatus works without nowTs parameter");
    } else {
        console.log("TEST_RESULT:no-nowts-param:FAIL:expected healthy, got " + status);
    }
}

// =====================================================
// Test 12: countWeekendDays with same-day (no days between)
// =====================================================
{
    const mon = makeTs(2026, 1, 5, 9, 0);
    const monLater = makeTs(2026, 1, 5, 17, 0);
    const result = countWeekendDays(mon, monLater);
    if (result === 0) {
        console.log("TEST_RESULT:count-weekend-same-day:PASS:same day returns 0");
    } else {
        console.log("TEST_RESULT:count-weekend-same-day:FAIL:expected 0, got " + result);
    }
}

// =====================================================
// Test 13: Explicit warning_days only (no error_days) still uses calendar days
// =====================================================
{
    const fridayCommit = makeTs(2026, 1, 2, 17, 0);
    const mondayNow = makeTs(2026, 1, 5, 9, 0);
    const repo = { name: "ExplicitWarning", last_commit_ts: fridayCommit, warning_days: 1.5 };
    const status = getRepoStatus(repo, mondayNow);
    // ~2.7 calendar days elapsed, warning_days=1.5 so should be warning or error
    if (status !== "healthy") {
        console.log("TEST_RESULT:explicit-warning-only:PASS:explicit warning_days uses calendar days (got " + status + ")");
    } else {
        console.log("TEST_RESULT:explicit-warning-only:FAIL:expected non-healthy for explicit warning_days");
    }
}
')

while IFS= read -r line; do
    case "$line" in
        TEST_RESULT:*)
            local_name="$(echo "$line" | cut -d: -f2)"
            local_result="$(echo "$line" | cut -d: -f3)"
            local_detail="$(echo "$line" | cut -d: -f4-)"
            if [ "$local_result" = "PASS" ]; then
                pass_test "$local_name — $local_detail"
            else
                fail_test "$local_name — $local_detail"
            fi
            ;;
    esac
done <<< "$OUTPUT"

echo ""
echo "=============================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
