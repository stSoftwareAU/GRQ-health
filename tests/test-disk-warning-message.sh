#!/bin/bash
# Test for Issue #84: Clarify high-disk warning message when caused by hysteresis
# Verifies that the disk warning message distinguishes between above-threshold
# and hysteresis-band cases.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #84: Disk warning message clarity"
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
// Test 1: buildDiskWarningMessage exists
{
    if (typeof buildDiskWarningMessage === "function") {
        console.log("TEST_RESULT:function-exists:PASS:buildDiskWarningMessage exists");
    } else {
        console.log("TEST_RESULT:function-exists:FAIL:buildDiskWarningMessage not found");
    }
}

// Test 2: Above threshold — message references the trigger threshold
{
    const msg = buildDiskWarningMessage(85, true);
    const expected = THRESHOLDS.DISK_WARNING_PERCENT;
    if (msg.includes(String(expected)) && msg.includes("85")) {
        console.log("TEST_RESULT:above-threshold-msg:PASS:message includes disk% and threshold: " + msg);
    } else {
        console.log("TEST_RESULT:above-threshold-msg:FAIL:expected threshold " + expected + " and 85 in message, got: " + msg);
    }
}

// Test 3: Above threshold — message contains >= symbol
{
    const msg = buildDiskWarningMessage(85, true);
    if (msg.includes(">=")) {
        console.log("TEST_RESULT:above-threshold-gte:PASS:message contains >= for above-threshold case");
    } else {
        console.log("TEST_RESULT:above-threshold-gte:FAIL:expected >= in message, got: " + msg);
    }
}

// Test 4: In hysteresis band — message mentions hysteresis
{
    const midPoint = (THRESHOLDS.DISK_WARNING_PERCENT + THRESHOLDS.DISK_WARNING_CLEAR_PERCENT) / 2;
    const msg = buildDiskWarningMessage(midPoint, true);
    if (msg.toLowerCase().includes("hysteresis")) {
        console.log("TEST_RESULT:hysteresis-msg:PASS:hysteresis band message mentions hysteresis: " + msg);
    } else {
        console.log("TEST_RESULT:hysteresis-msg:FAIL:expected hysteresis in message, got: " + msg);
    }
}

// Test 5: In hysteresis band — message references the clear threshold
{
    const midPoint = (THRESHOLDS.DISK_WARNING_PERCENT + THRESHOLDS.DISK_WARNING_CLEAR_PERCENT) / 2;
    const msg = buildDiskWarningMessage(midPoint, true);
    const clearThreshold = THRESHOLDS.DISK_WARNING_CLEAR_PERCENT;
    if (msg.includes(String(clearThreshold))) {
        console.log("TEST_RESULT:hysteresis-clear-threshold:PASS:hysteresis message includes clear threshold " + clearThreshold);
    } else {
        console.log("TEST_RESULT:hysteresis-clear-threshold:FAIL:expected clear threshold " + clearThreshold + " in message, got: " + msg);
    }
}

// Test 6: At exactly the warning threshold — uses above-threshold message
{
    const msg = buildDiskWarningMessage(THRESHOLDS.DISK_WARNING_PERCENT, true);
    if (msg.includes(">=") && !msg.toLowerCase().includes("hysteresis")) {
        console.log("TEST_RESULT:at-threshold-msg:PASS:at threshold uses above-threshold message: " + msg);
    } else {
        console.log("TEST_RESULT:at-threshold-msg:FAIL:at threshold should use above-threshold message, got: " + msg);
    }
}

// Test 7: Threshold values come from THRESHOLDS constants, not hardcoded
{
    const msg85 = buildDiskWarningMessage(85, true);
    const warnPct = THRESHOLDS.DISK_WARNING_PERCENT;
    const clearPct = THRESHOLDS.DISK_WARNING_CLEAR_PERCENT;
    const midPoint = (warnPct + clearPct) / 2;
    const msgBand = buildDiskWarningMessage(midPoint, true);
    // Verify the above-threshold message contains the warning threshold
    const aboveOk = msg85.includes(String(warnPct));
    // Verify the hysteresis message contains the clear threshold
    const bandOk = msgBand.includes(String(clearPct));
    if (aboveOk && bandOk) {
        console.log("TEST_RESULT:uses-thresholds:PASS:messages use THRESHOLDS constants (warn=" + warnPct + ", clear=" + clearPct + ")");
    } else {
        console.log("TEST_RESULT:uses-thresholds:FAIL:messages should reference THRESHOLDS constants, above:" + msg85 + " band:" + msgBand);
    }
}

// Test 8: Message starts with "High disk usage:" prefix
{
    const msg = buildDiskWarningMessage(85, true);
    if (msg.startsWith("High disk usage:")) {
        console.log("TEST_RESULT:prefix-above:PASS:above-threshold message starts with correct prefix");
    } else {
        console.log("TEST_RESULT:prefix-above:FAIL:expected prefix High disk usage:, got: " + msg);
    }
}

// Test 9: Hysteresis message also starts with "High disk usage:" prefix
{
    const midPoint = (THRESHOLDS.DISK_WARNING_PERCENT + THRESHOLDS.DISK_WARNING_CLEAR_PERCENT) / 2;
    const msg = buildDiskWarningMessage(midPoint, true);
    if (msg.startsWith("High disk usage:")) {
        console.log("TEST_RESULT:prefix-band:PASS:hysteresis message starts with correct prefix");
    } else {
        console.log("TEST_RESULT:prefix-band:FAIL:expected prefix High disk usage:, got: " + msg);
    }
}

// Test 10: Not in warning — returns empty string
{
    const msg = buildDiskWarningMessage(50, false);
    if (msg === "") {
        console.log("TEST_RESULT:no-warning-empty:PASS:returns empty when not in warning");
    } else {
        console.log("TEST_RESULT:no-warning-empty:FAIL:expected empty string, got: " + msg);
    }
}

// Test 11: In hysteresis band but not previously warning — returns empty string
{
    const midPoint = (THRESHOLDS.DISK_WARNING_PERCENT + THRESHOLDS.DISK_WARNING_CLEAR_PERCENT) / 2;
    const msg = buildDiskWarningMessage(midPoint, false);
    if (msg === "") {
        console.log("TEST_RESULT:band-no-prev-warning:PASS:returns empty when in band but not previously warning");
    } else {
        console.log("TEST_RESULT:band-no-prev-warning:FAIL:expected empty string for band without prev warning, got: " + msg);
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
