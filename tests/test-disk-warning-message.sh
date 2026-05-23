#!/bin/bash
# Test for Issue #84: Disk warning message clarifies hysteresis
# Verifies that the warning message distinguishes between above-threshold
# and hysteresis-band cases, using dynamic threshold values.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #84: Disk warning message clarifies hysteresis"
echo "============================================================="
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
// Test 1: buildDiskWarningMessage function exists
{
    if (typeof buildDiskWarningMessage === "function") {
        console.log("TEST_RESULT:function-exists:PASS:buildDiskWarningMessage function exists");
    } else {
        console.log("TEST_RESULT:function-exists:FAIL:buildDiskWarningMessage function not found");
    }
}

// Test 2: Above threshold — message references the trigger threshold
{
    const msg = buildDiskWarningMessage(95.2);
    const expected = THRESHOLDS.DISK_WARNING_PERCENT;
    if (msg.includes("95.2%") && msg.includes(String(expected) + "%")) {
        console.log("TEST_RESULT:above-threshold-msg:PASS:message includes usage and threshold: " + msg);
    } else {
        console.log("TEST_RESULT:above-threshold-msg:FAIL:expected usage 95.2% and threshold " + expected + "% in message, got: " + msg);
    }
}

// Test 3: At exactly the threshold — message references the trigger threshold
{
    const atThreshold = THRESHOLDS.DISK_WARNING_PERCENT;
    const msg = buildDiskWarningMessage(atThreshold);
    if (msg.includes(String(atThreshold) + "%") && msg.includes(">=" )) {
        console.log("TEST_RESULT:at-threshold-msg:PASS:message at threshold: " + msg);
    } else {
        console.log("TEST_RESULT:at-threshold-msg:FAIL:expected >= and threshold in message, got: " + msg);
    }
}

// Test 4: In hysteresis band — message mentions hysteresis and clear threshold
{
    const inBand = THRESHOLDS.DISK_WARNING_PERCENT - 1;
    const msg = buildDiskWarningMessage(inBand);
    const clearThreshold = THRESHOLDS.DISK_WARNING_CLEAR_PERCENT;
    if (msg.includes("hysteresis") && msg.includes(String(clearThreshold) + "%")) {
        console.log("TEST_RESULT:hysteresis-band-msg:PASS:message explains hysteresis: " + msg);
    } else {
        console.log("TEST_RESULT:hysteresis-band-msg:FAIL:expected hysteresis and clear threshold " + clearThreshold + "% in message, got: " + msg);
    }
}

// Test 5: In hysteresis band — message includes actual usage percentage
{
    const inBand = 78.4;
    const msg = buildDiskWarningMessage(inBand);
    if (msg.includes("78.4%")) {
        console.log("TEST_RESULT:hysteresis-shows-usage:PASS:hysteresis message includes usage: " + msg);
    } else {
        console.log("TEST_RESULT:hysteresis-shows-usage:FAIL:expected 78.4% in message, got: " + msg);
    }
}

// Test 6: Above threshold — message does NOT mention hysteresis
{
    const msg = buildDiskWarningMessage(95);
    if (!msg.includes("hysteresis")) {
        console.log("TEST_RESULT:above-no-hysteresis:PASS:above-threshold message does not mention hysteresis");
    } else {
        console.log("TEST_RESULT:above-no-hysteresis:FAIL:above-threshold message should not mention hysteresis, got: " + msg);
    }
}

// Test 7: Threshold values are dynamic (not hardcoded 90/87)
{
    const aboveMsg = buildDiskWarningMessage(THRESHOLDS.DISK_WARNING_PERCENT + 5);
    const bandMsg = buildDiskWarningMessage(THRESHOLDS.DISK_WARNING_PERCENT - 1);
    const warnPct = THRESHOLDS.DISK_WARNING_PERCENT;
    const clearPct = THRESHOLDS.DISK_WARNING_CLEAR_PERCENT;
    const aboveOk = aboveMsg.includes(String(warnPct) + "%");
    const bandOk = bandMsg.includes(String(clearPct) + "%");
    if (aboveOk && bandOk) {
        console.log("TEST_RESULT:dynamic-thresholds:PASS:messages use THRESHOLDS values " + warnPct + " and " + clearPct);
    } else {
        console.log("TEST_RESULT:dynamic-thresholds:FAIL:messages should use dynamic thresholds, aboveOk=" + aboveOk + " bandOk=" + bandOk);
    }
}

// Test 8: Message always starts with "High disk usage:"
{
    const msg1 = buildDiskWarningMessage(95);
    const msg2 = buildDiskWarningMessage(88);
    if (msg1.startsWith("High disk usage:") && msg2.startsWith("High disk usage:")) {
        console.log("TEST_RESULT:prefix-consistent:PASS:both messages start with High disk usage:");
    } else {
        console.log("TEST_RESULT:prefix-consistent:FAIL:messages should start with High disk usage:, got: [" + msg1 + "] and [" + msg2 + "]");
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
echo "============================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
