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
                  "DISK_WARNING_PERCENT", "DISK_WARNING_CLEAR_PERCENT", "HEARTBEAT_CRITICAL_HOURS",
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
                         "DISK_WARNING_PERCENT", "DISK_WARNING_CLEAR_PERCENT", "HEARTBEAT_CRITICAL_HOURS",
                         "USER_STALE_DEFAULT_HOURS", "IDLE_HIGH_LOAD"];
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

// Test 9: USER_STALE_DEFAULT_HOURS and IDLE_HIGH_LOAD exist
{
    const newKeys = ["USER_STALE_DEFAULT_HOURS", "IDLE_HIGH_LOAD"];
    const missing = newKeys.filter(k => THRESHOLDS[k] === undefined);
    if (missing.length === 0) {
        console.log("TEST_RESULT:new-keys-exist:PASS:USER_STALE_DEFAULT_HOURS and IDLE_HIGH_LOAD present");
    } else {
        console.log("TEST_RESULT:new-keys-exist:FAIL:missing keys: " + missing.join(", "));
    }
}

// Test 10: getUserHeartbeatWarningHours returns THRESHOLDS.USER_STALE_DEFAULT_HOURS when no per-host value
{
    const result = getUserHeartbeatWarningHours({});
    if (result === THRESHOLDS.USER_STALE_DEFAULT_HOURS) {
        console.log("TEST_RESULT:user-stale-default:PASS:default stale hours matches THRESHOLDS constant (" + result + ")");
    } else {
        console.log("TEST_RESULT:user-stale-default:FAIL:expected " + THRESHOLDS.USER_STALE_DEFAULT_HOURS + ", got " + result);
    }
}

// Test 11: getIdleWorkerStatus uses IDLE_HIGH_LOAD for recently-stopped-work detection
// When 15m load is above IDLE_HIGH_LOAD and 1m/5m are low, machine is NOT flagged idle
{
    const data = {
        load_averages: (THRESHOLDS.IDLE_LOAD_1M - 2) + "% (1m), " + (THRESHOLDS.IDLE_LOAD_15M - 2) + "% (5m), " + (THRESHOLDS.IDLE_HIGH_LOAD + 5) + "% (15m)",
        cpu_cores: String(THRESHOLDS.IDLE_MIN_CORES + 4)
    };
    const result = getIdleWorkerStatus(data);
    if (!result.isIdle) {
        console.log("TEST_RESULT:recently-stopped-work:PASS:high 15m with low 1m/5m not flagged idle");
    } else {
        console.log("TEST_RESULT:recently-stopped-work:FAIL:should not flag idle when work recently stopped");
    }
}

// Test 12: getIdleWorkerStatus uses IDLE_HIGH_LOAD for recently-started-work detection
// When 1m load is above IDLE_HIGH_LOAD and 15m is low, machine is NOT flagged idle
{
    const data = {
        load_averages: (THRESHOLDS.IDLE_HIGH_LOAD + 5) + "% (1m), " + (THRESHOLDS.IDLE_LOAD_5M - 2) + "% (5m), " + (THRESHOLDS.IDLE_LOAD_15M - 2) + "% (15m)",
        cpu_cores: String(THRESHOLDS.IDLE_MIN_CORES + 4)
    };
    const result = getIdleWorkerStatus(data);
    if (!result.isIdle) {
        console.log("TEST_RESULT:recently-started-work:PASS:high 1m with low 15m not flagged idle");
    } else {
        console.log("TEST_RESULT:recently-started-work:FAIL:should not flag idle when work recently started");
    }
}

// Test 13: Issue #131 — Disk warning threshold is 90%
{
    if (THRESHOLDS.DISK_WARNING_PERCENT === 90) {
        console.log("TEST_RESULT:disk-warning-90:PASS:DISK_WARNING_PERCENT is 90%");
    } else {
        console.log("TEST_RESULT:disk-warning-90:FAIL:expected 90, got " + THRESHOLDS.DISK_WARNING_PERCENT);
    }
}

// Test 14: Issue #131 — Disk warning clear threshold is 87% (3-point hysteresis)
{
    if (THRESHOLDS.DISK_WARNING_CLEAR_PERCENT === 87) {
        console.log("TEST_RESULT:disk-clear-87:PASS:DISK_WARNING_CLEAR_PERCENT is 87%");
    } else {
        console.log("TEST_RESULT:disk-clear-87:FAIL:expected 87, got " + THRESHOLDS.DISK_WARNING_CLEAR_PERCENT);
    }
}

// Test 15: Ubuntu version below THRESHOLDS.UBUNTU_MIN_VERSION triggers warning
{
    const now = Math.floor(Date.now() / 1000);
    const data = { heart_beat_ts: now, os_info: "Ubuntu", os_version: "20.04" };
    const status = getHealthStatus("test-ubuntu", data);
    if (status === "warning") {
        console.log("TEST_RESULT:ubuntu-min-version:PASS:Ubuntu below min version triggers warning");
    } else {
        console.log("TEST_RESULT:ubuntu-min-version:FAIL:expected warning, got " + status);
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
