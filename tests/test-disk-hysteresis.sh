#!/bin/bash
# Test for Issue #49: Disk usage hysteresis
# Verifies that disk warnings use hysteresis to avoid oscillation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #49: Disk usage hysteresis"
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
const now = Math.floor(Date.now() / 1000);

// Test 1: DISK_CLEAR_PERCENT threshold exists and is below DISK_WARNING_PERCENT
{
    if (THRESHOLDS.DISK_CLEAR_PERCENT !== undefined &&
        typeof THRESHOLDS.DISK_CLEAR_PERCENT === "number" &&
        THRESHOLDS.DISK_CLEAR_PERCENT < THRESHOLDS.DISK_WARNING_PERCENT) {
        console.log("TEST_RESULT:clear-threshold-exists:PASS:DISK_CLEAR_PERCENT=" + THRESHOLDS.DISK_CLEAR_PERCENT + " < DISK_WARNING_PERCENT=" + THRESHOLDS.DISK_WARNING_PERCENT);
    } else {
        console.log("TEST_RESULT:clear-threshold-exists:FAIL:DISK_CLEAR_PERCENT missing or not below DISK_WARNING_PERCENT");
    }
}

// Test 2: Disk clearly above warning threshold triggers warning (no previous state)
{
    const data = { heart_beat_ts: now, used_disk_percent: "80" };
    const status = getHealthStatus("test-host", data);
    if (status === "warning") {
        console.log("TEST_RESULT:above-threshold-warns:PASS:80% triggers warning");
    } else {
        console.log("TEST_RESULT:above-threshold-warns:FAIL:expected warning for 80%, got " + status);
    }
}

// Test 3: Disk clearly below clear threshold is healthy (no previous state)
{
    const data = { heart_beat_ts: now, used_disk_percent: "70" };
    const status = getHealthStatus("test-host", data);
    if (status === "healthy") {
        console.log("TEST_RESULT:below-clear-healthy:PASS:70% is healthy");
    } else {
        console.log("TEST_RESULT:below-clear-healthy:FAIL:expected healthy for 70%, got " + status);
    }
}

// Test 4: Disk in hysteresis band (between clear and warning) with no previous warning is healthy
{
    const data = { heart_beat_ts: now, used_disk_percent: "73" };
    const status = getHealthStatus("test-host", data, {});
    if (status === "healthy") {
        console.log("TEST_RESULT:band-no-prev-healthy:PASS:73% with no previous warning is healthy");
    } else {
        console.log("TEST_RESULT:band-no-prev-healthy:FAIL:expected healthy for 73% with no prev warning, got " + status);
    }
}

// Test 5: Disk in hysteresis band with previous disk warning stays warning
{
    const data = { heart_beat_ts: now, used_disk_percent: "73" };
    const status = getHealthStatus("test-host", data, { previousDiskWarning: true });
    if (status === "warning") {
        console.log("TEST_RESULT:band-prev-warn-stays:PASS:73% with previous disk warning stays warning");
    } else {
        console.log("TEST_RESULT:band-prev-warn-stays:FAIL:expected warning for 73% with prev disk warning, got " + status);
    }
}

// Test 6: Disk drops below clear threshold clears warning even with previous disk warning
{
    const data = { heart_beat_ts: now, used_disk_percent: String(THRESHOLDS.DISK_CLEAR_PERCENT - 1) };
    const status = getHealthStatus("test-host", data, { previousDiskWarning: true });
    if (status === "healthy") {
        console.log("TEST_RESULT:below-clear-clears:PASS:below clear threshold clears warning");
    } else {
        console.log("TEST_RESULT:below-clear-clears:FAIL:expected healthy below clear threshold with prev warning, got " + status);
    }
}

// Test 7: Disk at exactly the warning threshold does NOT trigger (must exceed)
{
    const data = { heart_beat_ts: now, used_disk_percent: String(THRESHOLDS.DISK_WARNING_PERCENT) };
    const status = getHealthStatus("test-host", data);
    if (status === "healthy") {
        console.log("TEST_RESULT:at-threshold-healthy:PASS:exactly at " + THRESHOLDS.DISK_WARNING_PERCENT + "% is healthy");
    } else {
        console.log("TEST_RESULT:at-threshold-healthy:FAIL:expected healthy at exactly " + THRESHOLDS.DISK_WARNING_PERCENT + "%, got " + status);
    }
}

// Test 8: Disk at exactly the clear threshold with previous warning stays warning (must drop below)
{
    const data = { heart_beat_ts: now, used_disk_percent: String(THRESHOLDS.DISK_CLEAR_PERCENT) };
    const status = getHealthStatus("test-host", data, { previousDiskWarning: true });
    if (status === "warning") {
        console.log("TEST_RESULT:at-clear-stays-warn:PASS:exactly at clear threshold with prev warning stays warning");
    } else {
        console.log("TEST_RESULT:at-clear-stays-warn:FAIL:expected warning at exactly clear threshold with prev warning, got " + status);
    }
}

// Test 9: Without options parameter, function still works (backwards compatibility)
{
    const data = { heart_beat_ts: now, used_disk_percent: "80" };
    const status = getHealthStatus("test-host", data);
    if (status === "warning") {
        console.log("TEST_RESULT:no-options-compat:PASS:works without options parameter");
    } else {
        console.log("TEST_RESULT:no-options-compat:FAIL:expected warning without options param, got " + status);
    }
}

// Test 10: Disk at 75.5% (just above threshold) triggers warning from healthy state
{
    const data = { heart_beat_ts: now, used_disk_percent: "75.5" };
    const status = getHealthStatus("test-host", data, { previousDiskWarning: false });
    if (status === "warning") {
        console.log("TEST_RESULT:just-above-triggers:PASS:75.5% triggers warning from healthy");
    } else {
        console.log("TEST_RESULT:just-above-triggers:FAIL:expected warning for 75.5% from healthy, got " + status);
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
