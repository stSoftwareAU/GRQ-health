#!/bin/bash
# Test for Issue #136: Record and display GPU usage per host (cross-platform)
# Verifies the pure formatGpuDisplay() helper that powers the dashboard GPU card.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #136: GPU usage display"
echo "====================================="
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
// Test 1: function exists
{
    if (typeof formatGpuDisplay === "function") {
        console.log("TEST_RESULT:function-exists:PASS:formatGpuDisplay defined");
    } else {
        console.log("TEST_RESULT:function-exists:FAIL:formatGpuDisplay not found");
    }
}

// Test 2: Apple Silicon — load, cores and model combine like the CPU card
{
    const r = formatGpuDisplay({ gpu_load: "45%", gpu_cores: "10", gpu_model: "Apple M2 Pro" });
    if (r === "45% (10 cores, Apple M2 Pro)") {
        console.log("TEST_RESULT:apple-full:PASS:" + r);
    } else {
        console.log("TEST_RESULT:apple-full:FAIL:got " + r);
    }
}

// Test 3: NVIDIA — no core count, model still appended
{
    const r = formatGpuDisplay({ gpu_load: "30%", gpu_cores: "N/A", gpu_model: "NVIDIA GeForce RTX 3080" });
    if (r === "30% (NVIDIA GeForce RTX 3080)") {
        console.log("TEST_RESULT:nvidia-no-cores:PASS:" + r);
    } else {
        console.log("TEST_RESULT:nvidia-no-cores:FAIL:got " + r);
    }
}

// Test 4: Bare numeric load is normalised to a percentage
{
    const r = formatGpuDisplay({ gpu_load: "12", gpu_model: "Apple M1" });
    if (r === "12% (Apple M1)") {
        console.log("TEST_RESULT:bare-number:PASS:" + r);
    } else {
        console.log("TEST_RESULT:bare-number:FAIL:got " + r);
    }
}

// Test 5: No GPU data at all degrades to N/A
{
    const r = formatGpuDisplay({});
    if (r === "N/A") {
        console.log("TEST_RESULT:no-data:PASS:" + r);
    } else {
        console.log("TEST_RESULT:no-data:FAIL:got " + r);
    }
}

// Test 6: Live % unreadable but model known still surfaces the GPU
{
    const r = formatGpuDisplay({ gpu_load: "N/A", gpu_cores: "8", gpu_model: "Apple M1" });
    if (r === "N/A (8 cores, Apple M1)") {
        console.log("TEST_RESULT:na-load-known-model:PASS:" + r);
    } else {
        console.log("TEST_RESULT:na-load-known-model:FAIL:got " + r);
    }
}

// Test 7: "unknown"/empty values are treated as absent
{
    const r = formatGpuDisplay({ gpu_load: "unknown", gpu_cores: "", gpu_model: "unknown" });
    if (r === "N/A") {
        console.log("TEST_RESULT:unknown-values:PASS:" + r);
    } else {
        console.log("TEST_RESULT:unknown-values:FAIL:got " + r);
    }
}

// Test 8: Missing fields (undefined) are handled without throwing
{
    const r = formatGpuDisplay({ gpu_load: "55%" });
    if (r === "55%") {
        console.log("TEST_RESULT:partial-fields:PASS:" + r);
    } else {
        console.log("TEST_RESULT:partial-fields:FAIL:got " + r);
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
echo "====================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
