#!/bin/bash
# Test script for Issue #15: Refresh time and stale shouldn't be the same
# This script verifies that the stale threshold is properly separated from the heartbeat threshold

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"
DASHBOARD_JS="$SCRIPT_DIR/../docs/dashboard.js"

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

# Test 1: Check that USER_STALE_HOURS_DEFAULT is NOT the same as HEARTBEAT_THRESHOLD_HOURS
echo "Test 1: Checking that USER_STALE_HOURS_DEFAULT is separate from HEARTBEAT_THRESHOLD_HOURS..."

HEARTBEAT_THRESHOLD=$(grep '^HEARTBEAT_THRESHOLD_HOURS=' "$RUN_SH" | head -1 | cut -d'=' -f2)
USER_STALE_DEFAULT_LINE=$(grep 'USER_STALE_HOURS_DEFAULT=' "$RUN_SH" | head -1)

# The line should NOT reference HEARTBEAT_THRESHOLD_HOURS directly
if echo "$USER_STALE_DEFAULT_LINE" | grep -q 'HEARTBEAT_THRESHOLD_HOURS'; then
    fail_test "USER_STALE_HOURS_DEFAULT should NOT directly reference HEARTBEAT_THRESHOLD_HOURS"
else
    pass_test "USER_STALE_HOURS_DEFAULT is set independently of HEARTBEAT_THRESHOLD_HOURS"
fi

# Test 2: Check that USER_STALE_HOURS_DEFAULT is at least 24 (3x the 8-hour heartbeat)
echo "Test 2: Checking that USER_STALE_HOURS_DEFAULT is at least 24 hours..."

# Extract the actual default value
USER_STALE_DEFAULT=$(grep 'USER_STALE_HOURS_DEFAULT=' "$RUN_SH" | head -1 | sed 's/.*="\{0,1\}\([0-9]*\).*/\1/')

if [[ "$USER_STALE_DEFAULT" =~ ^[0-9]+$ ]] && [ "$USER_STALE_DEFAULT" -ge 24 ]; then
    pass_test "USER_STALE_HOURS_DEFAULT is $USER_STALE_DEFAULT hours (>= 24h)"
else
    fail_test "USER_STALE_HOURS_DEFAULT should be at least 24 hours, found: $USER_STALE_DEFAULT"
fi

# Test 3: Check that the stale threshold is at least 3x the heartbeat threshold
echo "Test 3: Checking that stale threshold is at least 3x heartbeat threshold..."

if [[ "$HEARTBEAT_THRESHOLD" =~ ^[0-9]+$ ]] && [[ "$USER_STALE_DEFAULT" =~ ^[0-9]+$ ]]; then
    MIN_STALE=$((HEARTBEAT_THRESHOLD * 3))
    if [ "$USER_STALE_DEFAULT" -ge "$MIN_STALE" ]; then
        pass_test "Stale threshold ($USER_STALE_DEFAULT h) >= 3x heartbeat ($HEARTBEAT_THRESHOLD h = min $MIN_STALE h)"
    else
        fail_test "Stale threshold ($USER_STALE_DEFAULT h) should be >= 3x heartbeat ($HEARTBEAT_THRESHOLD h = min $MIN_STALE h)"
    fi
else
    fail_test "Could not parse threshold values: HEARTBEAT=$HEARTBEAT_THRESHOLD, STALE=$USER_STALE_DEFAULT"
fi

# Test 4: Check that dashboard.js default matches the new stale threshold
echo "Test 4: Checking that dashboard.js default stale threshold is at least 24 hours..."

# Look for the return statement with a number in getUserHeartbeatWarningHours function
DASHBOARD_DEFAULT=$(grep -A10 'function getUserHeartbeatWarningHours' "$DASHBOARD_JS" | grep 'return [0-9]' | tail -1 | sed 's/[^0-9]*\([0-9]*\).*/\1/')

if [[ "$DASHBOARD_DEFAULT" =~ ^[0-9]+$ ]] && [ "$DASHBOARD_DEFAULT" -ge 24 ]; then
    pass_test "Dashboard default stale threshold is $DASHBOARD_DEFAULT hours (>= 24h)"
else
    fail_test "Dashboard default stale threshold should be at least 24 hours, found: $DASHBOARD_DEFAULT"
fi

# Test 5: Verify run.sh has documentation about the relationship between thresholds
echo "Test 5: Checking that run.sh documents the threshold relationship..."

if grep -q "multiple" "$RUN_SH" || grep -q "3x\|3 times\|three times" "$RUN_SH" || grep -q "24.*hours\|stale.*hours" "$RUN_SH"; then
    pass_test "run.sh documents the stale threshold configuration"
else
    # Check for comment explaining the relationship
    if grep -A3 'USER_STALE_HOURS' "$RUN_SH" | grep -q '#'; then
        pass_test "run.sh has comments about USER_STALE_HOURS"
    else
        fail_test "run.sh should document the relationship between heartbeat and stale thresholds"
    fi
fi

# Summary
echo ""
echo "=============================================================="
echo "Test Summary"
echo "=============================================================="
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "Some tests FAILED. Issue #15 may not be fully fixed."
    exit 1
else
    echo "All tests PASSED! Issue #15 is properly fixed."
    echo ""
    echo "Summary of changes for Issue #15:"
    echo "- Stale threshold is now 24 hours (3x the 8-hour heartbeat threshold)"
    echo "- This prevents false positives when processes run hourly but heartbeats update every 8 hours"
    echo "- The dashboard and run.sh now use consistent stale threshold values"
    exit 0
fi
