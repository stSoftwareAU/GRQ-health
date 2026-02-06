#!/bin/bash
# Test script for Issue #23: Detecting idle workers
#
# These are functional "what" tests that call getIdleWorkerStatus() with real
# test data and verify the returned result. They do NOT grep source code.
#
# Key behaviour under test:
# - Workers with consistently low load averages (1m, 5m, 15m) are flagged as idle
# - Workers with high 15m but low 1m indicate work just finished (not idle)
# - Workers with low 15m but high 1m indicate work just started (not idle)
# - Only multi-core systems (> 4 cores) are checked
# - Missing data returns not-idle (graceful handling)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

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

TEST_OUTPUT=$(run_js_test '
// Test 1: All load averages low on multi-core system should be IDLE
{
    const data = {
        load_averages: "5.0% (1m), 5.0% (5m), 5.0% (15m)",
        cpu_cores: "16"
    };
    const result = getIdleWorkerStatus(data);
    const pass = result.isIdle === true;
    console.log("TEST_RESULT:All loads low on 16 cores is idle:" + (pass ? "PASS" : "FAIL") + ":isIdle=" + result.isIdle);
}

// Test 2: High load averages should NOT be idle
{
    const data = {
        load_averages: "85.0% (1m), 73.2% (5m), 56.6% (15m)",
        cpu_cores: "16"
    };
    const result = getIdleWorkerStatus(data);
    const pass = result.isIdle === false;
    console.log("TEST_RESULT:High loads is not idle:" + (pass ? "PASS" : "FAIL") + ":isIdle=" + result.isIdle);
}

// Test 3: Work just finished (high 15m, low 1m/5m) should NOT be idle
{
    const data = {
        load_averages: "5.0% (1m), 10.0% (5m), 55.0% (15m)",
        cpu_cores: "16"
    };
    const result = getIdleWorkerStatus(data);
    const pass = result.isIdle === false;
    console.log("TEST_RESULT:Work just finished is not idle:" + (pass ? "PASS" : "FAIL") + ":isIdle=" + result.isIdle);
}

// Test 4: Work just started (high 1m, low 15m) should NOT be idle
{
    const data = {
        load_averages: "75.0% (1m), 30.0% (5m), 10.0% (15m)",
        cpu_cores: "16"
    };
    const result = getIdleWorkerStatus(data);
    const pass = result.isIdle === false;
    console.log("TEST_RESULT:Work just started is not idle:" + (pass ? "PASS" : "FAIL") + ":isIdle=" + result.isIdle);
}

// Test 5: Small system (4 cores) should NOT be flagged as idle even with low loads
{
    const data = {
        load_averages: "2.0% (1m), 3.0% (5m), 1.0% (15m)",
        cpu_cores: "4"
    };
    const result = getIdleWorkerStatus(data);
    const pass = result.isIdle === false;
    console.log("TEST_RESULT:4-core system not checked for idle:" + (pass ? "PASS" : "FAIL") + ":isIdle=" + result.isIdle);
}

// Test 6: Missing load_averages should return not idle
{
    const data = { cpu_cores: "16" };
    const result = getIdleWorkerStatus(data);
    const pass = result.isIdle === false;
    console.log("TEST_RESULT:Missing load data returns not idle:" + (pass ? "PASS" : "FAIL") + ":isIdle=" + result.isIdle);
}

// Test 7: Missing cpu_cores should return not idle
{
    const data = { load_averages: "5.0% (1m), 5.0% (5m), 5.0% (15m)" };
    const result = getIdleWorkerStatus(data);
    const pass = result.isIdle === false;
    console.log("TEST_RESULT:Missing core count returns not idle:" + (pass ? "PASS" : "FAIL") + ":isIdle=" + result.isIdle);
}

// Test 8: Idle worker should trigger warning via getHealthStatus
{
    const now = Math.floor(Date.now() / 1000);
    const oneHourAgo = now - 3600;
    const data = {
        heart_beat_ts: oneHourAgo,
        os_info: "macOS",
        os_version: "15.0",
        load_averages: "5.0% (1m), 5.0% (5m), 5.0% (15m)",
        cpu_cores: "16"
    };
    const status = getHealthStatus("GRQ-IDLE", data);
    const pass = status === "warning";
    console.log("TEST_RESULT:Idle worker triggers warning status:" + (pass ? "PASS" : "FAIL") + ":status=" + status);
}

// Test 9: Idle reason includes load percentages
{
    const data = {
        load_averages: "3.5% (1m), 4.2% (5m), 6.1% (15m)",
        cpu_cores: "8"
    };
    const result = getIdleWorkerStatus(data);
    const pass = result.isIdle === true && result.reason.includes("3.5") && result.reason.includes("4.2");
    console.log("TEST_RESULT:Idle reason includes load values:" + (pass ? "PASS" : "FAIL") + ":reason=" + result.reason);
}

// Test 10: Core count is correctly parsed
{
    const data = {
        load_averages: "5.0% (1m), 5.0% (5m), 5.0% (15m)",
        cpu_cores: "24"
    };
    const result = getIdleWorkerStatus(data);
    const pass = result.coreCount === 24;
    console.log("TEST_RESULT:Core count is parsed correctly:" + (pass ? "PASS" : "FAIL") + ":coreCount=" + result.coreCount);
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
echo "========================================="
echo "Test Summary"
echo "========================================="
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
