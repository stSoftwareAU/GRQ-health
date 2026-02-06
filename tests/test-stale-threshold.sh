#!/bin/bash
# Test script for Issue #15: Refresh time and stale shouldn't be the same
#
# These are functional "what" tests that call getUserHeartbeatWarningHours()
# and related functions with real test data to verify behaviour. They do NOT
# grep source code.
#
# Key behaviour under test:
# - Default stale threshold is 24 hours (3x the 8-hour heartbeat threshold)
# - Custom thresholds via user_stale_hours are respected
# - A user updated 10 hours ago is NOT stale under the default 24h threshold
# - A user updated 25 hours ago IS stale under the default 24h threshold
# - run.sh USER_STALE_HOURS_DEFAULT matches the dashboard default

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

RUN_SH="$SCRIPT_DIR/../run.sh"

echo "Testing Issue #15: Refresh time and stale threshold separation"
echo "=============================================================="
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

# Test run.sh configuration value
HEARTBEAT_THRESHOLD=$(grep '^HEARTBEAT_THRESHOLD_HOURS=' "$RUN_SH" | head -1 | cut -d'=' -f2)
USER_STALE_DEFAULT=$(grep '^USER_STALE_HOURS_DEFAULT=' "$RUN_SH" | head -1 | cut -d'=' -f2)

echo "Test 1: Checking run.sh USER_STALE_HOURS_DEFAULT >= 24..."
if [[ "$USER_STALE_DEFAULT" =~ ^[0-9]+$ ]] && [ "$USER_STALE_DEFAULT" -ge 24 ]; then
    pass_test "run.sh USER_STALE_HOURS_DEFAULT is $USER_STALE_DEFAULT (>= 24)"
else
    fail_test "run.sh USER_STALE_HOURS_DEFAULT should be >= 24, found: $USER_STALE_DEFAULT"
fi

echo "Test 2: Checking stale threshold >= 3x heartbeat threshold..."
if [[ "$HEARTBEAT_THRESHOLD" =~ ^[0-9]+$ ]] && [[ "$USER_STALE_DEFAULT" =~ ^[0-9]+$ ]]; then
    MIN_STALE=$((HEARTBEAT_THRESHOLD * 3))
    if [ "$USER_STALE_DEFAULT" -ge "$MIN_STALE" ]; then
        pass_test "Stale ($USER_STALE_DEFAULT h) >= 3x heartbeat ($HEARTBEAT_THRESHOLD h = min $MIN_STALE h)"
    else
        fail_test "Stale ($USER_STALE_DEFAULT h) should be >= 3x heartbeat ($HEARTBEAT_THRESHOLD h = min $MIN_STALE h)"
    fi
else
    fail_test "Could not parse threshold values"
fi

# Functional tests via deno
TEST_OUTPUT=$(run_js_test '
const now = Math.floor(Date.now() / 1000);

// Test 3: Default stale threshold should be 24 hours
{
    const data = {};
    const hours = getUserHeartbeatWarningHours(data);
    const pass = hours === 24;
    console.log("TEST_RESULT:Default stale threshold is 24h:" + (pass ? "PASS" : "FAIL") + ":hours=" + hours);
}

// Test 4: Custom stale threshold of 48h should be respected
{
    const data = { user_stale_hours: 48 };
    const hours = getUserHeartbeatWarningHours(data);
    const pass = hours === 48;
    console.log("TEST_RESULT:Custom 48h threshold respected:" + (pass ? "PASS" : "FAIL") + ":hours=" + hours);
}

// Test 5: User updated 10 hours ago should NOT be stale (default 24h threshold)
{
    const tenHoursAgo = now - (10 * 3600);
    const data = {
        users: {
            sloth: { heart_beat_ts: tenHoursAgo },
            rocket: { heart_beat_ts: now - 3600 }
        }
    };
    const staleUsers = getStaleUsers(data, now);
    const pass = staleUsers.length === 0;
    console.log("TEST_RESULT:User 10h ago not stale:" + (pass ? "PASS" : "FAIL") + ":staleCount=" + staleUsers.length);
}

// Test 6: User updated 25 hours ago SHOULD be stale (default 24h threshold)
{
    const twentyFiveHoursAgo = now - (25 * 3600);
    const data = {
        users: {
            sloth: { heart_beat_ts: twentyFiveHoursAgo },
            rocket: { heart_beat_ts: now - 3600 }
        }
    };
    const staleUsers = getStaleUsers(data, now);
    const isSlothStale = staleUsers.some(u => u.username === "sloth");
    const pass = isSlothStale;
    console.log("TEST_RESULT:User 25h ago is stale:" + (pass ? "PASS" : "FAIL") + ":staleCount=" + staleUsers.length);
}

// Test 7: User updated 8 hours ago should NOT be stale (regression for issue #15)
{
    const eightHoursAgo = now - (8 * 3600);
    const data = {
        users: {
            sloth: { heart_beat_ts: eightHoursAgo },
            rocket: { heart_beat_ts: now - 3600 }
        }
    };
    const staleUsers = getStaleUsers(data, now);
    const pass = staleUsers.length === 0;
    console.log("TEST_RESULT:User 8h ago not stale (regression):" + (pass ? "PASS" : "FAIL") + ":staleCount=" + staleUsers.length);
}

// Test 8: With custom 48h threshold, user at 30h is NOT stale
{
    const thirtyHoursAgo = now - (30 * 3600);
    const data = {
        user_stale_hours: 48,
        users: {
            sloth: { heart_beat_ts: thirtyHoursAgo },
            rocket: { heart_beat_ts: now - 3600 }
        }
    };
    const staleUsers = getStaleUsers(data, now);
    const pass = staleUsers.length === 0;
    console.log("TEST_RESULT:Custom 48h threshold, 30h user not stale:" + (pass ? "PASS" : "FAIL") + ":staleCount=" + staleUsers.length);
}
')

while IFS= read -r line; do
    case "$line" in
        TEST_RESULT:*:PASS:*)
            name=$(echo "$line" | cut -d: -f2)
            pass_test "$name"
            ;;
        TEST_RESULT:*:FAIL:*)
            name=$(echo "$line" | cut -d: -f2)
            detail=$(echo "$line" | cut -d: -f4-)
            fail_test "$name ($detail)"
            ;;
    esac
done <<< "$TEST_OUTPUT"

echo ""
echo "=============================================================="
echo "Test Summary"
echo "=============================================================="
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "Some tests FAILED."
    exit 1
else
    echo "All tests PASSED!"
    exit 0
fi
