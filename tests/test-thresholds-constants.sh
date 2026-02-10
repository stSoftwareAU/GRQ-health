#!/bin/bash
# Test for Issue #35: Named constants replace magic numbers
# Verifies that THRESHOLDS constants exist and are used by health logic

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #35: Named threshold constants"
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
// Test 1: THRESHOLDS object exists with expected keys
{
    const keys = ["IDLE_MIN_CORES", "IDLE_LOAD_1M", "IDLE_LOAD_5M", "IDLE_LOAD_15M",
                  "DISK_WARNING_PERCENT", "HEARTBEAT_CRITICAL_HOURS",
                  "MACOS_MIN_VERSION", "UBUNTU_MIN_VERSION"];
    const missing = keys.filter(k => THRESHOLDS[k] === undefined);
    if (missing.length === 0) {
        console.log("TEST_RESULT:thresholds-exist:PASS:all threshold keys present");
    } else {
        console.log("TEST_RESULT:thresholds-exist:FAIL:missing keys: " + missing.join(", "));
    }
}

// Test 2: Disk warning threshold used by getHealthStatus
{
    const now = Math.floor(Date.now() / 1000);
    const data = { heart_beat_ts: now, used_disk_percent: String(THRESHOLDS.DISK_WARNING_PERCENT + 1) };
    const status = getHealthStatus("test-host", data);
    if (status === "warning") {
        console.log("TEST_RESULT:disk-threshold:PASS:disk over threshold gives warning");
    } else {
        console.log("TEST_RESULT:disk-threshold:FAIL:expected warning, got " + status);
    }
}

// Test 3: Disk below threshold is healthy
{
    const now = Math.floor(Date.now() / 1000);
    const data = { heart_beat_ts: now, used_disk_percent: String(THRESHOLDS.DISK_WARNING_PERCENT - 1) };
    const status = getHealthStatus("test-host", data);
    if (status === "healthy") {
        console.log("TEST_RESULT:disk-healthy:PASS:disk below threshold is healthy");
    } else {
        console.log("TEST_RESULT:disk-healthy:FAIL:expected healthy, got " + status);
    }
}

// Test 4: Heartbeat critical threshold used by getHealthStatus
{
    const now = Math.floor(Date.now() / 1000);
    const oldTs = now - (THRESHOLDS.HEARTBEAT_CRITICAL_HOURS + 1) * 3600;
    const data = { heart_beat_ts: oldTs };
    const status = getHealthStatus("test-host", data);
    if (status === "critical") {
        console.log("TEST_RESULT:heartbeat-critical:PASS:old heartbeat gives critical");
    } else {
        console.log("TEST_RESULT:heartbeat-critical:FAIL:expected critical, got " + status);
    }
}

// Test 5: Idle worker detection uses THRESHOLDS.IDLE_MIN_CORES
{
    // Machine with fewer cores than threshold should NOT be checked for idle
    const data = {
        load_averages: "5.0% (1m), 5.0% (5m), 5.0% (15m)",
        cpu_cores: String(THRESHOLDS.IDLE_MIN_CORES)
    };
    const result = getIdleWorkerStatus(data);
    if (!result.isIdle) {
        console.log("TEST_RESULT:idle-min-cores:PASS:machine at min cores not flagged idle");
    } else {
        console.log("TEST_RESULT:idle-min-cores:FAIL:machine at min cores should not be flagged idle");
    }
}

// Test 6: Idle worker detection uses load thresholds
{
    const data = {
        load_averages: (THRESHOLDS.IDLE_LOAD_1M - 1) + "% (1m), " + (THRESHOLDS.IDLE_LOAD_5M - 1) + "% (5m), " + (THRESHOLDS.IDLE_LOAD_15M - 1) + "% (15m)",
        cpu_cores: String(THRESHOLDS.IDLE_MIN_CORES + 4)
    };
    const result = getIdleWorkerStatus(data);
    if (result.isIdle) {
        console.log("TEST_RESULT:idle-load-thresholds:PASS:low load on multi-core flagged idle");
    } else {
        console.log("TEST_RESULT:idle-load-thresholds:FAIL:expected idle detection with low loads");
    }
}

// Test 7: OS version thresholds match expected values
{
    const now = Math.floor(Date.now() / 1000);
    const data = { heart_beat_ts: now, os_info: "macOS", os_version: THRESHOLDS.MACOS_MIN_VERSION };
    const status = getHealthStatus("test-mac", data);
    // At or above min version should not trigger OS warning
    if (status !== "warning") {
        console.log("TEST_RESULT:macos-min-version:PASS:macOS at min version is not warning");
    } else {
        console.log("TEST_RESULT:macos-min-version:FAIL:macOS at min version should not be warning");
    }
}

// Test 8: THRESHOLDS values are sensible numbers/strings
{
    const numericKeys = ["IDLE_MIN_CORES", "IDLE_LOAD_1M", "IDLE_LOAD_5M", "IDLE_LOAD_15M",
                         "DISK_WARNING_PERCENT", "HEARTBEAT_CRITICAL_HOURS"];
    const badValues = numericKeys.filter(k => typeof THRESHOLDS[k] !== "number" || THRESHOLDS[k] <= 0);
    const stringKeys = ["MACOS_MIN_VERSION", "UBUNTU_MIN_VERSION"];
    const badStrings = stringKeys.filter(k => typeof THRESHOLDS[k] !== "string" || THRESHOLDS[k].length === 0);
    const allBad = [...badValues, ...badStrings];
    if (allBad.length === 0) {
        console.log("TEST_RESULT:sensible-values:PASS:all threshold values are sensible");
    } else {
        console.log("TEST_RESULT:sensible-values:FAIL:bad threshold values: " + allBad.join(", "));
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
