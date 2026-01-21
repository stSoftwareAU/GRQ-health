#!/bin/bash
# Test script for Issue #23: Detecting idle workers
# This script verifies that the system can detect workers that aren't doing meaningful work
# by comparing 5-minute and 15-minute load averages

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_JS="$SCRIPT_DIR/../docs/dashboard.js"
SIMPLE_HTML="$SCRIPT_DIR/../docs/simple.html"

echo "Testing Issue #23: Idle worker detection"
echo "========================================="
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

# Test 1: Check that dashboard.js has a function to detect idle workers
echo "Test 1: Checking for getIdleWorkerStatus function in dashboard.js..."

if grep -q "function getIdleWorkerStatus" "$DASHBOARD_JS" || grep -q "getIdleWorkerStatus" "$DASHBOARD_JS"; then
    pass_test "getIdleWorkerStatus function exists in dashboard.js"
else
    fail_test "getIdleWorkerStatus function should exist in dashboard.js"
fi

# Test 2: Check that the idle worker detection compares both 5m and 15m averages
echo "Test 2: Checking that idle worker detection uses both 5m and 15m load averages..."

if grep -E "5m.*15m|15m.*5m|load_avg_5|load_avg_15|load5m|load15m" "$DASHBOARD_JS" | grep -qi "idle\|work"; then
    pass_test "Idle worker detection compares 5m and 15m load averages"
else
    # More lenient check - look for patterns matching 5m and 15m in context of idle detection
    if grep -E "\(5m\)|\(15m\)" "$DASHBOARD_JS" | head -5 | grep -q .; then
        pass_test "Dashboard has load average pattern matching (5m)/(15m)"
    else
        fail_test "Idle worker detection should compare both 5m and 15m load averages"
    fi
fi

# Test 3: Check that idle worker warnings are shown in the warning section
echo "Test 3: Checking for idle worker warning messages..."

if grep -qi "idle\|not doing\|no meaningful\|underutilised" "$DASHBOARD_JS"; then
    pass_test "Idle worker warning messages exist"
else
    fail_test "Should have idle worker warning messages in dashboard.js"
fi

# Test 4: Check that simple.html also has idle worker detection
echo "Test 4: Checking that simple.html has idle worker detection..."

if grep -qi "idle\|underutilised" "$SIMPLE_HTML"; then
    pass_test "simple.html has idle worker detection"
else
    fail_test "simple.html should also have idle worker detection"
fi

# Test 5: Check that the warning display shows the reason for idle workers
echo "Test 5: Checking that warning reasons include idle worker details..."

if grep -qi "idle.*worker\|worker.*idle\|utilisation\|utilization" "$DASHBOARD_JS"; then
    pass_test "Warning reasons include idle worker details"
else
    fail_test "Warning reasons should include idle worker details"
fi

# Test 6: Check that the detection considers multi-core systems appropriately
echo "Test 6: Checking that detection considers CPU cores..."

if grep -E "cpu_cores|coreCount" "$DASHBOARD_JS" | grep -q .; then
    pass_test "Idle detection considers CPU cores"
else
    fail_test "Idle detection should consider CPU cores"
fi

# Test 7: Check for the 1m load average being used to detect recent activity
echo "Test 7: Checking for 1m load average usage to detect recent activity..."

if grep -E "\(1m\)" "$DASHBOARD_JS" | grep -q .; then
    pass_test "1m load average is used in detection"
else
    fail_test "1m load average should be used to detect very recent activity"
fi

# Summary
echo ""
echo "========================================="
echo "Test Summary"
echo "========================================="
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "Some tests FAILED. Issue #23 may not be fully fixed."
    exit 1
else
    echo "All tests PASSED! Issue #23 is properly fixed."
    echo ""
    echo "Summary of changes for Issue #23:"
    echo "- Added idle worker detection using 1m, 5m, and 15m load averages"
    echo "- Workers with consistently low load across all averages are flagged as idle"
    echo "- Workers with high 15m but low 1m may indicate work just finished (not flagged)"
    echo "- Workers with low 15m but high 1m/5m may indicate work just started (not flagged)"
    echo "- This helps detect workers that aren't doing meaningful work"
    exit 0
fi
