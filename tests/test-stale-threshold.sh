#!/bin/bash
# Test for Issue #15: Refresh time and stale shouldn't be the same
# Verifies that the stale threshold is properly separated from the heartbeat
# threshold in both run.sh config and dashboard.js logic.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

RUN_SH="$SCRIPT_DIR/../run.sh"

echo "Testing Issue #15: Stale threshold separation"
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

# Test 1: run.sh HEARTBEAT_THRESHOLD_HOURS and USER_STALE_HOURS_DEFAULT are different
echo "Test 1: Checking config values in run.sh..."

HEARTBEAT_THRESHOLD=$(grep '^HEARTBEAT_THRESHOLD_HOURS=' "$RUN_SH" | head -1 | cut -d'=' -f2)
USER_STALE_DEFAULT=$(grep '^USER_STALE_HOURS_DEFAULT=' "$RUN_SH" | head -1 | cut -d'=' -f2)

if [ "$HEARTBEAT_THRESHOLD" != "$USER_STALE_DEFAULT" ]; then
    pass_test "HEARTBEAT ($HEARTBEAT_THRESHOLD h) != USER_STALE_DEFAULT ($USER_STALE_DEFAULT h)"
else
    fail_test "HEARTBEAT and USER_STALE_DEFAULT should be different values"
fi

# Test 2: Stale threshold is at least 3x the heartbeat threshold
echo "Test 2: Checking stale >= 3x heartbeat..."

if [[ "$HEARTBEAT_THRESHOLD" =~ ^[0-9]+$ ]] && [[ "$USER_STALE_DEFAULT" =~ ^[0-9]+$ ]]; then
    MIN_STALE=$((HEARTBEAT_THRESHOLD * 3))
    if [ "$USER_STALE_DEFAULT" -ge "$MIN_STALE" ]; then
        pass_test "Stale ($USER_STALE_DEFAULT h) >= 3x heartbeat ($HEARTBEAT_THRESHOLD h)"
    else
        fail_test "Stale ($USER_STALE_DEFAULT h) should be >= 3x heartbeat ($HEARTBEAT_THRESHOLD h = min $MIN_STALE h)"
    fi
else
    fail_test "Could not parse threshold values"
fi

# Test 3: getUserHeartbeatWarningHours returns correct default via JS
echo "Test 3: Checking getUserHeartbeatWarningHours default..."

OUTPUT=$(run_js_test '
// Test 3: Default stale threshold should be 24 hours
{
    const hours = getUserHeartbeatWarningHours({});
    if (hours === 24) {
        console.log("TEST_RESULT:default-stale:PASS:default is 24 hours");
    } else {
        console.log("TEST_RESULT:default-stale:FAIL:expected 24, got " + hours);
    }
}

// Test 4: Per-host override is respected
{
    const hours = getUserHeartbeatWarningHours({ user_stale_hours: 48 });
    if (hours === 48) {
        console.log("TEST_RESULT:override-stale:PASS:per-host override to 48 hours works");
    } else {
        console.log("TEST_RESULT:override-stale:FAIL:expected 48, got " + hours);
    }
}

// Test 5: Invalid override falls back to default
{
    const hours = getUserHeartbeatWarningHours({ user_stale_hours: -1 });
    if (hours === 24) {
        console.log("TEST_RESULT:invalid-override:PASS:invalid override falls back to 24");
    } else {
        console.log("TEST_RESULT:invalid-override:FAIL:expected 24, got " + hours);
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
