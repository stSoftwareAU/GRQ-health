#!/bin/bash
# Test for Issue #26: Last seen an hour ago isn't a critical issue
# Calls getHealthStatus() with test data to verify that a multi-user host
# with a recent host heartbeat but a stale user is WARNING, not CRITICAL.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #26: Critical vs warning for stale users"
echo "======================================================="
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
// Use a fixed "now" so tests are deterministic
const NOW_TS = 1700000000;
const _originalDateNow = Date.now;
Date.now = () => NOW_TS * 1000;

// Test 1: Host seen 1 hour ago with a stale user should be WARNING, not CRITICAL
{
    const oneHourAgo = NOW_TS - 3600;
    const twoDaysAgo = NOW_TS - 2 * 86400;
    const data = {
        heart_beat_ts: oneHourAgo,
        users: {
            alice: { heart_beat_ts: oneHourAgo },
            bob:   { heart_beat_ts: twoDaysAgo }
        }
    };
    const status = getHealthStatus("TestHost", data);
    if (status === "warning") {
        console.log("TEST_RESULT:recent-host-stale-user:PASS:status is warning (not critical)");
    } else {
        console.log("TEST_RESULT:recent-host-stale-user:FAIL:expected warning, got " + status);
    }
}

// Test 2: Host not seen for 48 hours (no users) should be CRITICAL
{
    const twoDaysAgo = NOW_TS - 2 * 86400;
    const data = { heart_beat_ts: twoDaysAgo };
    const status = getHealthStatus("OldHost", data);
    if (status === "critical") {
        console.log("TEST_RESULT:old-host-critical:PASS:status is critical");
    } else {
        console.log("TEST_RESULT:old-host-critical:FAIL:expected critical, got " + status);
    }
}

// Test 3: Host seen 1 hour ago, all users fresh — should be HEALTHY
{
    const oneHourAgo = NOW_TS - 3600;
    const data = {
        heart_beat_ts: oneHourAgo,
        users: {
            alice: { heart_beat_ts: oneHourAgo },
            bob:   { heart_beat_ts: oneHourAgo }
        }
    };
    const status = getHealthStatus("FreshHost", data);
    if (status === "healthy") {
        console.log("TEST_RESULT:fresh-host-healthy:PASS:status is healthy");
    } else {
        console.log("TEST_RESULT:fresh-host-healthy:FAIL:expected healthy, got " + status);
    }
}

// Test 4: Dead machine returns dead regardless of heartbeat
{
    const data = { death_date: "1 Jan 2024", heart_beat_ts: 0 };
    const status = getHealthStatus("DeadHost", data);
    if (status === "dead") {
        console.log("TEST_RESULT:dead-host:PASS:status is dead");
    } else {
        console.log("TEST_RESULT:dead-host:FAIL:expected dead, got " + status);
    }
}

// Test 5: Mobile host not seen for 48h should be MIA, not critical
{
    const twoDaysAgo = NOW_TS - 2 * 86400;
    const data = { heart_beat_ts: twoDaysAgo, mobile: true };
    const status = getHealthStatus("MobileHost", data);
    if (status === "mia") {
        console.log("TEST_RESULT:mobile-mia:PASS:status is mia");
    } else {
        console.log("TEST_RESULT:mobile-mia:FAIL:expected mia, got " + status);
    }
}

// Test 6: Single-user host seen recently should be healthy (no stale user check)
{
    const oneHourAgo = NOW_TS - 3600;
    const data = {
        heart_beat_ts: oneHourAgo,
        users: {
            alice: { heart_beat_ts: oneHourAgo }
        }
    };
    const status = getHealthStatus("SingleUser", data);
    if (status === "healthy") {
        console.log("TEST_RESULT:single-user-healthy:PASS:status is healthy");
    } else {
        console.log("TEST_RESULT:single-user-healthy:FAIL:expected healthy, got " + status);
    }
}

Date.now = _originalDateNow;
')

while IFS= read -r line; do
    case "$line" in
        TEST_RESULT:*) check_result "$line" ;;
    esac
done <<< "$OUTPUT"

echo ""
echo "======================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
