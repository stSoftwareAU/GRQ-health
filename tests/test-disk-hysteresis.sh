#!/bin/bash
# Test for Issue #49: Disk usage warning hysteresis
# Verifies that disk warnings use hysteresis to prevent oscillation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #49: Disk usage warning hysteresis"
echo "================================================="
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

// Test 1: DISK_WARNING_CLEAR_PERCENT exists and is below DISK_WARNING_PERCENT
{
    if (THRESHOLDS.DISK_WARNING_CLEAR_PERCENT !== undefined &&
        THRESHOLDS.DISK_WARNING_CLEAR_PERCENT < THRESHOLDS.DISK_WARNING_PERCENT) {
        console.log("TEST_RESULT:clear-threshold-exists:PASS:DISK_WARNING_CLEAR_PERCENT=" +
            THRESHOLDS.DISK_WARNING_CLEAR_PERCENT + " < DISK_WARNING_PERCENT=" +
            THRESHOLDS.DISK_WARNING_PERCENT);
    } else {
        console.log("TEST_RESULT:clear-threshold-exists:FAIL:DISK_WARNING_CLEAR_PERCENT missing or not below DISK_WARNING_PERCENT");
    }
}

// Test 2: isDiskWarning function exists
{
    if (typeof isDiskWarning === "function") {
        console.log("TEST_RESULT:function-exists:PASS:isDiskWarning function exists");
    } else {
        console.log("TEST_RESULT:function-exists:FAIL:isDiskWarning function not found");
    }
}

// Test 3: Disk clearly above threshold triggers warning (not previously warning)
{
    const result = isDiskWarning(95, false);
    if (result === true) {
        console.log("TEST_RESULT:above-triggers:PASS:95% triggers warning");
    } else {
        console.log("TEST_RESULT:above-triggers:FAIL:95% should trigger warning, got " + result);
    }
}

// Test 4: Disk clearly below clear threshold clears warning (previously warning)
{
    const result = isDiskWarning(70, true);
    if (result === false) {
        console.log("TEST_RESULT:below-clears:PASS:70% clears warning");
    } else {
        console.log("TEST_RESULT:below-clears:FAIL:70% should clear warning, got " + result);
    }
}

// Test 5: Disk in hysteresis band stays warning when previously warning
{
    const midPoint = (THRESHOLDS.DISK_WARNING_PERCENT + THRESHOLDS.DISK_WARNING_CLEAR_PERCENT) / 2;
    const result = isDiskWarning(midPoint, true);
    if (result === true) {
        console.log("TEST_RESULT:band-stays-warning:PASS:" + midPoint + "% stays warning when previously warning");
    } else {
        console.log("TEST_RESULT:band-stays-warning:FAIL:" + midPoint + "% should stay warning, got " + result);
    }
}

// Test 6: Disk in hysteresis band stays healthy when not previously warning
{
    const midPoint = (THRESHOLDS.DISK_WARNING_PERCENT + THRESHOLDS.DISK_WARNING_CLEAR_PERCENT) / 2;
    const result = isDiskWarning(midPoint, false);
    if (result === false) {
        console.log("TEST_RESULT:band-stays-healthy:PASS:" + midPoint + "% stays healthy when not previously warning");
    } else {
        console.log("TEST_RESULT:band-stays-healthy:FAIL:" + midPoint + "% should stay healthy, got " + result);
    }
}

// Test 7: Disk at exactly the warning threshold triggers warning
{
    const result = isDiskWarning(THRESHOLDS.DISK_WARNING_PERCENT, false);
    if (result === true) {
        console.log("TEST_RESULT:at-warning-threshold:PASS:exactly " + THRESHOLDS.DISK_WARNING_PERCENT + "% triggers warning");
    } else {
        console.log("TEST_RESULT:at-warning-threshold:FAIL:exactly " + THRESHOLDS.DISK_WARNING_PERCENT + "% should trigger, got " + result);
    }
}

// Test 8: Disk at exactly the clear threshold clears warning
{
    const result = isDiskWarning(THRESHOLDS.DISK_WARNING_CLEAR_PERCENT, true);
    if (result === false) {
        console.log("TEST_RESULT:at-clear-threshold:PASS:exactly " + THRESHOLDS.DISK_WARNING_CLEAR_PERCENT + "% clears warning");
    } else {
        console.log("TEST_RESULT:at-clear-threshold:FAIL:exactly " + THRESHOLDS.DISK_WARNING_CLEAR_PERCENT + "% should clear, got " + result);
    }
}

// Test 9: getHealthStatus with disk in hysteresis band and previous warning stays warning
{
    const midPoint = (THRESHOLDS.DISK_WARNING_PERCENT + THRESHOLDS.DISK_WARNING_CLEAR_PERCENT) / 2;
    const data = { heart_beat_ts: now, used_disk_percent: String(midPoint) };
    const status = getHealthStatus("test-host", data, { diskWarningActive: true });
    if (status === "warning") {
        console.log("TEST_RESULT:health-band-warning:PASS:getHealthStatus stays warning in hysteresis band");
    } else {
        console.log("TEST_RESULT:health-band-warning:FAIL:expected warning, got " + status);
    }
}

// Test 10: getHealthStatus with disk in hysteresis band and no previous warning stays healthy
{
    const midPoint = (THRESHOLDS.DISK_WARNING_PERCENT + THRESHOLDS.DISK_WARNING_CLEAR_PERCENT) / 2;
    const data = { heart_beat_ts: now, used_disk_percent: String(midPoint) };
    const status = getHealthStatus("test-host", data, { diskWarningActive: false });
    if (status === "healthy") {
        console.log("TEST_RESULT:health-band-healthy:PASS:getHealthStatus stays healthy in hysteresis band");
    } else {
        console.log("TEST_RESULT:health-band-healthy:FAIL:expected healthy, got " + status);
    }
}

// Test 11: getHealthStatus without options defaults to no previous warning (backward compatible)
{
    const data = { heart_beat_ts: now, used_disk_percent: String(THRESHOLDS.DISK_WARNING_PERCENT - 1) };
    const status = getHealthStatus("test-host", data);
    if (status === "healthy") {
        console.log("TEST_RESULT:backward-compat:PASS:no options still works correctly");
    } else {
        console.log("TEST_RESULT:backward-compat:FAIL:expected healthy without options, got " + status);
    }
}

// Test 12: Disk at threshold does not oscillate — stays warning once triggered
{
    // Use threshold-relative values to avoid hardcoding
    const above = THRESHOLDS.DISK_WARNING_PERCENT + 1;
    const atThreshold = THRESHOLDS.DISK_WARNING_PERCENT;
    const belowThresholdInBand = THRESHOLDS.DISK_WARNING_PERCENT - 1;
    // First check: above threshold triggers warning
    const trigger = isDiskWarning(above, false);
    // Second check: drops to exactly threshold — still in hysteresis band, should stay warning
    const stays = isDiskWarning(atThreshold, true);
    // Third check: drops below threshold but still in band — should stay warning
    const stays2 = isDiskWarning(belowThresholdInBand, true);
    if (trigger && stays && stays2) {
        console.log("TEST_RESULT:no-oscillation:PASS:" + above + "->" + atThreshold + "->" + belowThresholdInBand + " does not oscillate");
    } else {
        console.log("TEST_RESULT:no-oscillation:FAIL:expected true,true,true got " + trigger + "," + stays + "," + stays2);
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
echo "================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
