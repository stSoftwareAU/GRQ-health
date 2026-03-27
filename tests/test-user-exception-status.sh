#!/bin/bash
# Test for Issue #69: Per-user status badge should reflect exception_count
# When a user has exceptions (exception_count > 0), their status badge should
# show "errors" instead of "ok", even if their heartbeat is recent.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #69: Per-user exception status badge"
echo "==================================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

check_result() {
    local line="$1"
    local name result detail
    name="$(echo "$line" | cut -d: -f2)"
    result="$(echo "$line" | cut -d: -f3)"
    detail="$(echo "$line" | cut -d: -f4-)"
    if [ "$result" = "PASS" ]; then
        echo "  PASS: $name — $detail"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: $name — $detail"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

OUTPUT=$(run_js_test '
const NOW_TS = 1700000000;
const ONE_HOUR_AGO = NOW_TS - 3600;
const TWO_DAYS_AGO = NOW_TS - 2 * 86400;

// Test 1: User with exceptions and recent heartbeat should have status "errors"
{
    const userData = { heart_beat_ts: ONE_HOUR_AGO, exception_count: 3, exception_summary: "3 errors found" };
    const warnHours = 24;
    const status = getUserStatus(userData, NOW_TS, warnHours);
    if (status === "errors") {
        console.log("TEST_RESULT:exception-user-errors:PASS:user with exceptions correctly shows errors");
    } else {
        console.log("TEST_RESULT:exception-user-errors:FAIL:expected errors, got " + status);
    }
}

// Test 2: User with no exceptions and recent heartbeat should be "ok"
{
    const userData = { heart_beat_ts: ONE_HOUR_AGO, exception_count: 0, exception_summary: "No errors found" };
    const warnHours = 24;
    const status = getUserStatus(userData, NOW_TS, warnHours);
    if (status === "ok") {
        console.log("TEST_RESULT:no-exception-ok:PASS:user without exceptions correctly shows ok");
    } else {
        console.log("TEST_RESULT:no-exception-ok:FAIL:expected ok, got " + status);
    }
}

// Test 3: User who is stale should still show "stale" even with exceptions
{
    const userData = { heart_beat_ts: TWO_DAYS_AGO, exception_count: 2, exception_summary: "2 errors found" };
    const warnHours = 24;
    const status = getUserStatus(userData, NOW_TS, warnHours);
    if (status === "stale") {
        console.log("TEST_RESULT:stale-takes-priority:PASS:stale status takes priority over exceptions");
    } else {
        console.log("TEST_RESULT:stale-takes-priority:FAIL:expected stale, got " + status);
    }
}

// Test 4: User with no heartbeat at all should be "stale"
{
    const userData = { exception_count: 1, exception_summary: "1 errors found" };
    const warnHours = 24;
    const status = getUserStatus(userData, NOW_TS, warnHours);
    if (status === "stale") {
        console.log("TEST_RESULT:no-heartbeat-stale:PASS:missing heartbeat correctly shows stale");
    } else {
        console.log("TEST_RESULT:no-heartbeat-stale:FAIL:expected stale, got " + status);
    }
}

// Test 5: User with exception_count as string "1" should still show "errors"
{
    const userData = { heart_beat_ts: ONE_HOUR_AGO, exception_count: "1", exception_summary: "1 errors found" };
    const warnHours = 24;
    const status = getUserStatus(userData, NOW_TS, warnHours);
    if (status === "errors") {
        console.log("TEST_RESULT:string-exception-count:PASS:string exception_count correctly handled");
    } else {
        console.log("TEST_RESULT:string-exception-count:FAIL:expected errors, got " + status);
    }
}

// Test 6: User with exception_count of 0 as string should be "ok"
{
    const userData = { heart_beat_ts: ONE_HOUR_AGO, exception_count: "0" };
    const warnHours = 24;
    const status = getUserStatus(userData, NOW_TS, warnHours);
    if (status === "ok") {
        console.log("TEST_RESULT:string-zero-exception:PASS:string zero exception_count shows ok");
    } else {
        console.log("TEST_RESULT:string-zero-exception:FAIL:expected ok, got " + status);
    }
}

// Test 7: User with no exception_count field should be "ok" (if heartbeat is recent)
{
    const userData = { heart_beat_ts: ONE_HOUR_AGO };
    const warnHours = 24;
    const status = getUserStatus(userData, NOW_TS, warnHours);
    if (status === "ok") {
        console.log("TEST_RESULT:missing-exception-field:PASS:missing exception_count shows ok");
    } else {
        console.log("TEST_RESULT:missing-exception-field:FAIL:expected ok, got " + status);
    }
}

// Test 8: getHealthStatus should return warning when any user has exceptions (not stale)
{
    const recentTs = Math.floor(Date.now() / 1000) - 3600; // 1 hour ago
    const data = {
        heart_beat_ts: recentTs,
        users: {
            elephant: { heart_beat_ts: recentTs, exception_count: 1, exception_summary: "1 errors found" },
            rocket:   { heart_beat_ts: recentTs, exception_count: 0, exception_summary: "No errors found" }
        },
        exception_count: 1,
        exception_summary: "1 errors across 2 user(s)"
    };
    const status = getHealthStatus("Mac-Ultra-M2", data, {});
    if (status === "warning") {
        console.log("TEST_RESULT:host-exception-warning:PASS:host with user exceptions is warning");
    } else {
        console.log("TEST_RESULT:host-exception-warning:FAIL:expected warning, got " + status);
    }
}

// Test 9: getHealthStatus catches per-user exceptions even when host-level exception_count is missing
{
    const recentTs = Math.floor(Date.now() / 1000) - 3600;
    const data = {
        heart_beat_ts: recentTs,
        users: {
            elephant: { heart_beat_ts: recentTs, exception_count: 1, exception_summary: "1 errors found" },
            rocket:   { heart_beat_ts: recentTs, exception_count: 0, exception_summary: "No errors found" }
        }
        // Note: no host-level exception_count
    };
    const status = getHealthStatus("TestHost", data, {});
    if (status === "warning") {
        console.log("TEST_RESULT:per-user-exception-no-host:PASS:per-user exceptions detected without host-level count");
    } else {
        console.log("TEST_RESULT:per-user-exception-no-host:FAIL:expected warning, got " + status);
    }
}

// Test 10: getHealthStatus returns healthy when no users have exceptions and all fresh
{
    const recentTs = Math.floor(Date.now() / 1000) - 3600;
    const data = {
        heart_beat_ts: recentTs,
        users: {
            elephant: { heart_beat_ts: recentTs, exception_count: 0 },
            rocket:   { heart_beat_ts: recentTs, exception_count: 0 }
        }
    };
    const status = getHealthStatus("TestHost", data, {});
    if (status === "healthy") {
        console.log("TEST_RESULT:no-exceptions-healthy:PASS:host without exceptions is healthy");
    } else {
        console.log("TEST_RESULT:no-exceptions-healthy:FAIL:expected healthy, got " + status);
    }
}
')

while IFS= read -r line; do
    case "$line" in
        TEST_RESULT:*) check_result "$line" ;;
    esac
done <<< "$OUTPUT"

echo ""
echo "==================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
