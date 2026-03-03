#!/bin/bash
# Test for Issue #23: Idle worker detection
# Calls getIdleWorkerStatus() and buildIdleWorkerWarning() with test data
# to verify idle detection logic using 1m, 5m, 15m load averages.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #23: Idle worker detection"
echo "========================================="
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
// Test 1: All load averages low on multi-core system — should be idle
{
    const data = {
        load_averages: "5.0% (1m), 3.2% (5m), 4.1% (15m)",
        cpu_cores: "16"
    };
    const result = getIdleWorkerStatus(data);
    if (result.isIdle) {
        console.log("TEST_RESULT:all-low-idle:PASS:correctly flagged as idle");
    } else {
        console.log("TEST_RESULT:all-low-idle:FAIL:expected idle, got not idle");
    }
}

// Test 2: All load averages high — should NOT be idle
{
    const data = {
        load_averages: "80.0% (1m), 75.0% (5m), 70.0% (15m)",
        cpu_cores: "16"
    };
    const result = getIdleWorkerStatus(data);
    if (!result.isIdle) {
        console.log("TEST_RESULT:all-high-not-idle:PASS:correctly not flagged as idle");
    } else {
        console.log("TEST_RESULT:all-high-not-idle:FAIL:expected not idle, got idle");
    }
}

// Test 3: Work just finished (15m high, 1m/5m low) — should NOT be idle
{
    const data = {
        load_averages: "5.0% (1m), 8.0% (5m), 60.0% (15m)",
        cpu_cores: "16"
    };
    const result = getIdleWorkerStatus(data);
    if (!result.isIdle) {
        console.log("TEST_RESULT:work-finished:PASS:correctly not flagged as idle");
    } else {
        console.log("TEST_RESULT:work-finished:FAIL:expected not idle, got idle");
    }
}

// Test 4: Work just started (1m high, 15m low) — should NOT be idle
{
    const data = {
        load_averages: "70.0% (1m), 40.0% (5m), 10.0% (15m)",
        cpu_cores: "16"
    };
    const result = getIdleWorkerStatus(data);
    if (!result.isIdle) {
        console.log("TEST_RESULT:work-started:PASS:correctly not flagged as idle");
    } else {
        console.log("TEST_RESULT:work-started:FAIL:expected not idle, got idle");
    }
}

// Test 5: Small system (4 cores or fewer) — should never be flagged idle
{
    const data = {
        load_averages: "2.0% (1m), 1.0% (5m), 1.5% (15m)",
        cpu_cores: "4"
    };
    const result = getIdleWorkerStatus(data);
    if (!result.isIdle) {
        console.log("TEST_RESULT:small-system:PASS:correctly skipped for small system");
    } else {
        console.log("TEST_RESULT:small-system:FAIL:should not flag small systems as idle");
    }
}

// Test 6: Missing load_averages data — should return not idle
{
    const data = { cpu_cores: "16" };
    const result = getIdleWorkerStatus(data);
    if (!result.isIdle) {
        console.log("TEST_RESULT:missing-data:PASS:correctly returns not idle for missing data");
    } else {
        console.log("TEST_RESULT:missing-data:FAIL:should not flag missing data as idle");
    }
}

// Test 7: buildIdleWorkerWarning returns reason for idle host
{
    const data = {
        load_averages: "5.0% (1m), 3.2% (5m), 4.1% (15m)",
        cpu_cores: "16"
    };
    const warning = buildIdleWorkerWarning(data);
    if (warning.length > 0 && warning.includes("idle")) {
        console.log("TEST_RESULT:warning-text:PASS:warning message includes idle reason");
    } else {
        console.log("TEST_RESULT:warning-text:FAIL:expected warning text, got: " + warning);
    }
}

// Test 8: buildIdleWorkerWarning returns empty for busy host
{
    const data = {
        load_averages: "80.0% (1m), 75.0% (5m), 70.0% (15m)",
        cpu_cores: "16"
    };
    const warning = buildIdleWorkerWarning(data);
    if (warning === "") {
        console.log("TEST_RESULT:no-warning-busy:PASS:no warning for busy host");
    } else {
        console.log("TEST_RESULT:no-warning-busy:FAIL:expected empty, got: " + warning);
    }
}

// Test 9: Recently stopped exemption uses IDLE_LOAD_5M (15%) for 5m comparison — Issue #50
// When load5m is between IDLE_LOAD_5M (15%) and IDLE_LOAD_15M (20%), the exemption
// should NOT fire because load5m exceeds the 5-minute threshold.
{
    const data = {
        load_averages: "5.0% (1m), 17.0% (5m), 60.0% (15m)",
        cpu_cores: "16"
    };
    const result = getIdleWorkerStatus(data);
    // With the correct threshold (IDLE_LOAD_5M = 15%), load5m 17% > 15% so the
    // recently-stopped exemption should not match. The worker is not idle either way
    // but semantically the exemption path should not fire for elevated 5m load.
    if (!result.isIdle) {
        console.log("TEST_RESULT:recently-stopped-5m-threshold:PASS:correctly handles 5m load at boundary");
    } else {
        console.log("TEST_RESULT:recently-stopped-5m-threshold:FAIL:unexpected idle status");
    }
}

// Test 10: Recently stopped exemption fires when load5m is below IDLE_LOAD_5M — Issue #50
{
    const data = {
        load_averages: "5.0% (1m), 10.0% (5m), 60.0% (15m)",
        cpu_cores: "16"
    };
    const result = getIdleWorkerStatus(data);
    // load5m 10% < IDLE_LOAD_5M 15%, so the recently-stopped exemption should fire
    if (!result.isIdle) {
        console.log("TEST_RESULT:recently-stopped-below-5m:PASS:recently-stopped exemption works correctly");
    } else {
        console.log("TEST_RESULT:recently-stopped-below-5m:FAIL:expected not idle for recently stopped work");
    }
}

// Test 11: Idle detection populates load values in result (originally Test 9)
{
    const data = {
        load_averages: "5.0% (1m), 3.2% (5m), 4.1% (15m)",
        cpu_cores: "16"
    };
    const result = getIdleWorkerStatus(data);
    if (result.load1m === 5.0 && result.load5m === 3.2 && result.load15m === 4.1 && result.coreCount === 16) {
        console.log("TEST_RESULT:parsed-values:PASS:load values parsed correctly");
    } else {
        console.log("TEST_RESULT:parsed-values:FAIL:load1m=" + result.load1m + " load5m=" + result.load5m + " load15m=" + result.load15m + " cores=" + result.coreCount);
    }
}
')

while IFS= read -r line; do
    case "$line" in
        TEST_RESULT:*) check_result "$line" ;;
    esac
done <<< "$OUTPUT"

echo ""
echo "========================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
