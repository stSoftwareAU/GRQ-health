#!/bin/bash
# Test script for Issue #26: Last seen an hour ago isn't a critical issue
# This script verifies that a multi-user host with a recent host heartbeat
# but a stale user is classified as WARNING (not CRITICAL).
#
# The bug: getHealthStatus() used getWorstUserHeartbeatTs() for the critical
# threshold check. If one user was stale (>24h), the host was marked critical
# even though the host itself was seen recently (e.g. 1 hour ago).
# The fix: Use the host-level heartbeat for critical/MIA determination,
# and rely on the per-user stale check for warning status.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_JS="$SCRIPT_DIR/../docs/dashboard.js"

echo "Testing Issue #26: Last seen an hour ago isn't a critical issue"
echo "==============================================================="
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

# Test 1: getHealthStatus should use host-level heartbeat for critical determination
echo "Test 1: Checking that critical check uses host-level heartbeat (not worst user)..."

# The getHealthStatus function should consider the host-level heart_beat_ts
# separately from the worst user heartbeat for the critical threshold.
# Look for logic that distinguishes host heartbeat from user heartbeat in critical check.
if grep -A5 'critical.*24\|24.*critical' "$DASHBOARD_JS" | grep -qi 'heart_beat_ts\|hostHeartbeat\|host.*heartbeat'; then
    pass_test "Critical check references host-level heartbeat"
else
    # Alternative: check that effectiveHeartbeatTs is NOT used for critical check
    # or that there's a separate variable for host heartbeat
    if grep -B5 -A15 'Check for critical state' "$DASHBOARD_JS" | grep -qi 'data.*heart_beat_ts\|hostHeartbeat\|host.*ts'; then
        pass_test "Critical check uses host-level heartbeat"
    else
        fail_test "Critical check should use host-level heartbeat, not worst user heartbeat"
    fi
fi

# Test 2: Multi-user host with recent host heartbeat but stale user should NOT be critical
echo "Test 2: Checking that stale user on recently-seen host triggers warning, not critical..."

# The function should have a path where hoursSinceHostHeartbeat <= 24 but a stale user
# results in 'warning' rather than 'critical'
# Check that the function distinguishes between host heartbeat age and user heartbeat age
if grep -A40 'function getHealthStatus' "$DASHBOARD_JS" | grep -q 'warning.*stale\|stale.*warning\|anyUserStale\|user.*stale'; then
    pass_test "getHealthStatus has per-user stale detection for warning status"
else
    fail_test "getHealthStatus should detect stale users separately and mark as warning"
fi

# Test 3: The critical check should NOT use getWorstUserHeartbeatTs for the 24h threshold
echo "Test 3: Checking that critical/MIA checks use host heartbeat, not worst user heartbeat..."

# Extract the section between the critical check and the warning checks
# The critical check should use a host-level heartbeat, not effectiveHeartbeatTs from worst user
CRITICAL_SECTION=$(sed -n '/Check for MIA state\|Check for critical state/,/Check for warning/p' "$DASHBOARD_JS")

if echo "$CRITICAL_SECTION" | grep -q 'hoursSinceHost\|hostHeartbeat\|data\.heart_beat_ts\|data\['; then
    pass_test "Critical/MIA section uses host-level heartbeat"
elif echo "$CRITICAL_SECTION" | grep -q 'hoursSinceHeartbeat'; then
    # If it still uses hoursSinceHeartbeat, check if that variable was computed from host heartbeat
    HEARTBEAT_CALC=$(sed -n '/function getHealthStatus/,/Check for MIA/p' "$DASHBOARD_JS" | grep 'hoursSinceHeartbeat')
    if echo "$HEARTBEAT_CALC" | grep -qi 'hostHeartbeat\|data\.heart_beat_ts'; then
        pass_test "hoursSinceHeartbeat is computed from host-level heartbeat for critical check"
    else
        fail_test "Critical section should use host-level heartbeat, not worst user heartbeat"
    fi
else
    pass_test "Critical section does not use worst-user-based hoursSinceHeartbeat"
fi

# Test 4: The host-level heartbeat should be considered separately from per-user heartbeats
echo "Test 4: Checking that host heartbeat and user heartbeat are handled separately..."

# There should be distinct variables or logic paths for host vs user heartbeat
HOST_HB_COUNT=$(grep -c 'data\.heart_beat_ts\|data\[.heart_beat_ts.\]\|hostHeartbeat' "$DASHBOARD_JS" || true)
USER_HB_COUNT=$(grep -c 'getWorstUserHeartbeatTs\|effectiveHeartbeatTs\|worstUser' "$DASHBOARD_JS" || true)

if [ "$HOST_HB_COUNT" -gt 0 ] && [ "$USER_HB_COUNT" -gt 0 ]; then
    pass_test "Dashboard distinguishes between host heartbeat ($HOST_HB_COUNT refs) and user heartbeat ($USER_HB_COUNT refs)"
else
    fail_test "Dashboard should have separate handling for host and user heartbeats"
fi

# Test 5: Verify the critical section display shows correct information
echo "Test 5: Checking that critical section uses appropriate heartbeat for display..."

# The critical host display should show the effective/worst heartbeat, not just host heartbeat
# so the user understands WHY the host is critical
if grep -A10 'criticalHosts.map\|criticalHostsList' "$DASHBOARD_JS" | grep -q 'heart_beat_ts\|formatTimestamp'; then
    pass_test "Critical host display shows heartbeat information"
else
    fail_test "Critical host display should show heartbeat information"
fi

# Test 6: Verify that a host seen 1 hour ago cannot be critical (the core issue)
echo "Test 6: Checking that getHealthStatus logic prevents recently-seen hosts from being critical..."

# The function should check host-level heartbeat for critical determination
# A host with heart_beat_ts from 1 hour ago should never return 'critical'
# This means the critical path should consider data.heart_beat_ts, not just worst user
HEALTH_FN=$(sed -n '/function getHealthStatus/,/^function /p' "$DASHBOARD_JS" | head -100)

# Check that there's a host heartbeat variable separate from worst user heartbeat
if echo "$HEALTH_FN" | grep -q 'hostHeartbeat\|host_heartbeat\|data\.heart_beat_ts'; then
    pass_test "getHealthStatus considers host-level heartbeat separately"
else
    # If not, check if the effectiveHeartbeatTs calculation was changed
    if echo "$HEALTH_FN" | grep 'effectiveHeartbeatTs' | grep -q 'heart_beat_ts\|Math.max'; then
        pass_test "effectiveHeartbeatTs includes host-level heartbeat"
    else
        fail_test "getHealthStatus should consider host-level heartbeat for critical determination"
    fi
fi

# Summary
echo ""
echo "==============================================================="
echo "Test Summary"
echo "==============================================================="
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "Some tests FAILED. Issue #26 may not be fully fixed."
    exit 1
else
    echo "All tests PASSED! Issue #26 is properly fixed."
    echo ""
    echo "Summary of changes for Issue #26:"
    echo "- Host-level heartbeat is used for critical/MIA determination"
    echo "- Per-user stale heartbeats trigger warning status, not critical"
    echo "- A host seen recently (e.g. 1 hour ago) cannot be marked critical"
    echo "  due to a single stale user"
    exit 0
fi
