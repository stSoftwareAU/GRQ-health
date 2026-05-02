#!/bin/bash
# Test for Issue #61: Exclude [MemoryMonitor] when scanning for WARNING/ERROR
# MemoryMonitor warnings about cache clearing are operational noise, not real errors.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"
DENO="$HOME/.deno/bin/deno"

echo "Testing Issue #61: MemoryMonitor exclusion from error scanning"
echo "==============================================================="
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

# Create a temporary directory for test log files
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Extract the scan_log_errors function from run.sh
eval "$(sed -n '/^scan_log_errors()/,/^}/p' "$RUN_SH")"

# --- run.sh scan_log_errors tests ---

echo "Part 1: scan_log_errors() in run.sh"
echo "------------------------------------"

# Test 1: MemoryMonitor warning lines should NOT be counted
echo "Test 1: MemoryMonitor warning lines are excluded..."
HOME="$WORK_DIR"
mkdir -p "$WORK_DIR/logs"
# NODE_PID is read by the eval'd scan_log_errors function from run.sh
# shellcheck disable=SC2034
NODE_PID=""
cat > "$WORK_DIR/logs/node.log" << 'EOF'
run_core pid=20689 start=Sat Mar  7 21:30:59 AEDT 2026
[MemoryMonitor] Warning-level response: reduced activation cache cap from 100 to 50, evicted 25 entries
[MemoryMonitor] Heap: 180 MB / 217 MB (82.7%) [WARNING]
[MemoryMonitor] Critical-level response: cleared all WASM caches, activation cap reduced to 1, compilation cache cleared
[MemoryMonitor] Heap: 1581 MB / 1649 MB (95.9%) [CRITICAL]
Option: IntelligentDesign
HEAD is now at 8f0cfaf Evolution score 0.4065 -> 0.4066
EOF

scan_log_errors

# exception_count and exception_summary are set as globals inside scan_log_errors
# shellcheck disable=SC2154
if [ "$exception_count" -eq 0 ]; then
    pass_test "MemoryMonitor-only log has zero errors (count=$exception_count)"
else
    # shellcheck disable=SC2154
    fail_test "MemoryMonitor lines were falsely flagged: $exception_summary"
fi

# Test 2: MemoryMonitor with warning emoji should NOT be counted
echo "Test 2: MemoryMonitor with warning emoji excluded..."
cat > "$WORK_DIR/logs/node.log" << 'EOF'
run_core pid=20689
[MemoryMonitor] ⚠️ High memory usage detected (85.2%)
[MemoryMonitor] Heap: 500 MB / 600 MB (83.3%) [WARNING]
EOF

scan_log_errors

if [ "$exception_count" -eq 0 ]; then
    pass_test "MemoryMonitor with emoji has zero errors (count=$exception_count)"
else
    fail_test "MemoryMonitor emoji lines were falsely flagged: $exception_summary"
fi

# Test 3: Real errors mixed with MemoryMonitor lines — only real errors counted
echo "Test 3: Real errors still detected alongside MemoryMonitor lines..."
cat > "$WORK_DIR/logs/node.log" << 'EOF'
run_core pid=20689
[MemoryMonitor] Warning-level response: reduced activation cache cap from 100 to 50
[MemoryMonitor] Heap: 180 MB / 217 MB (82.7%) [WARNING]
Error: Something went wrong
    at Object.runInContext (vm.js:130:16)
    at main (index.js:52:8)
⚠️ Disk space running low
EOF

scan_log_errors

if [ "$exception_count" -eq 2 ]; then
    pass_test "Real errors counted correctly alongside MemoryMonitor (count=$exception_count)"
else
    fail_test "Expected 2 errors, got $exception_count: $exception_summary"
fi

# Test 4: MemoryMonitor with failure emoji should NOT be counted
echo "Test 4: MemoryMonitor with failure emoji excluded..."
cat > "$WORK_DIR/logs/node.log" << 'EOF'
[MemoryMonitor] ❌ Failed to free enough memory
EOF

scan_log_errors

if [ "$exception_count" -eq 0 ]; then
    pass_test "MemoryMonitor with failure emoji has zero errors (count=$exception_count)"
else
    fail_test "MemoryMonitor failure emoji was falsely flagged: $exception_summary"
fi

# Test 5: Real GRQ-18 node-rocket.log MemoryMonitor lines should not be counted
echo "Test 5: Actual MemoryMonitor log content from GRQ-18..."
cat > "$WORK_DIR/logs/node.log" << 'EOF'
Download https://jsr.io/@stsoftware/neat-ai/0.316.31/src/NEAT/MemoryMonitor.ts
[MemoryMonitor] Critical-level response: cleared all WASM caches, activation cap reduced to 1, compilation cache cleared
[MemoryMonitor] Heap: 1581 MB / 1649 MB (95.9%) [CRITICAL]
[MemoryMonitor] Critical-level response: cleared all WASM caches, activation cap reduced to 1, compilation cache cleared
[MemoryMonitor] Heap: 1334 MB / 1406 MB (94.9%) [CRITICAL]
EOF

scan_log_errors

if [ "$exception_count" -eq 0 ]; then
    pass_test "Actual GRQ-18 MemoryMonitor log has zero errors (count=$exception_count)"
else
    fail_test "Actual GRQ-18 MemoryMonitor lines falsely flagged: $exception_summary"
fi

# --- log-viewer.html classification tests ---

echo ""
echo "Part 2: log-viewer.html classification"
echo "---------------------------------------"

check_result() {
    local line="$1"
    local name result detail
    name="$(echo "$line" | cut -d: -f2)"
    result="$(echo "$line" | cut -d: -f3)"
    detail="$(echo "$line" | cut -d: -f4-)"
    if [ "$result" = "PASS" ]; then
        pass_test "$name — $detail"
    else
        fail_test "$name — $detail"
    fi
}

OUTPUT=$("$DENO" run - <<'DENO_SCRIPT'
// Extract classification logic matching log-viewer.html processLogContent
function classifyLine(line) {
    const isStackTraceLine = /^\s+at /.test(line);
    const isCStackTraceLine = /^\s+\d+\s+[^\s]+\s+0x[0-9a-fA-F]+/.test(line);

    // Exclude MemoryMonitor lines from warning/error classification
    if (line.includes('[MemoryMonitor]')) {
        return 'normal';
    }

    if (line.includes('ERROR') ||
        line.includes('Exception') ||
        line.startsWith('Error:') ||
        /Discovery failed for .+ after .+: Error:/.test(line) ||
        /\bfailed\b.*Error:/.test(line) ||
        /Fatal JavaScript out of memory/.test(line) ||
        /==== C stack trace/.test(line) ||
        /Fatal error/.test(line)) {
        return 'error-line';
    } else if (line.includes('\u274C')) {  // ❌
        return 'error-line';
    } else if (isStackTraceLine || isCStackTraceLine) {
        return 'stack-trace-line';
    } else if (line.includes('WARNING') || line.includes('Warning:') || line.includes('\u26A0\uFE0F')) {  // ⚠️
        return 'warning-line';
    } else if (line.includes('DEBUG:')) {
        return 'debug-line';
    } else {
        return 'normal';
    }
}

// Test: MemoryMonitor WARNING line should be classified as normal
{
    const line = "[MemoryMonitor] Heap: 180 MB / 217 MB (82.7%) [WARNING]";
    const cls = classifyLine(line);
    if (cls === "normal") {
        console.log("TEST_RESULT:memmon-warning-normal:PASS:MemoryMonitor WARNING classified as normal");
    } else {
        console.log("TEST_RESULT:memmon-warning-normal:FAIL:expected normal, got " + cls);
    }
}

// Test: MemoryMonitor CRITICAL line should be classified as normal
{
    const line = "[MemoryMonitor] Heap: 1581 MB / 1649 MB (95.9%) [CRITICAL]";
    const cls = classifyLine(line);
    if (cls === "normal") {
        console.log("TEST_RESULT:memmon-critical-normal:PASS:MemoryMonitor CRITICAL classified as normal");
    } else {
        console.log("TEST_RESULT:memmon-critical-normal:FAIL:expected normal, got " + cls);
    }
}

// Test: MemoryMonitor Warning-level response should be classified as normal
{
    const line = "[MemoryMonitor] Warning-level response: reduced activation cache cap from 100 to 50";
    const cls = classifyLine(line);
    if (cls === "normal") {
        console.log("TEST_RESULT:memmon-warning-response:PASS:MemoryMonitor warning response classified as normal");
    } else {
        console.log("TEST_RESULT:memmon-warning-response:FAIL:expected normal, got " + cls);
    }
}

// Test: Real WARNING line should STILL be classified as warning
{
    const line = "WARNING: Disk space running low";
    const cls = classifyLine(line);
    if (cls === "warning-line") {
        console.log("TEST_RESULT:real-warning-still-flagged:PASS:real WARNING still classified as warning");
    } else {
        console.log("TEST_RESULT:real-warning-still-flagged:FAIL:expected warning-line, got " + cls);
    }
}

// Test: Real ERROR line should STILL be classified as error
{
    const line = "ERROR: Something went wrong";
    const cls = classifyLine(line);
    if (cls === "error-line") {
        console.log("TEST_RESULT:real-error-still-flagged:PASS:real ERROR still classified as error");
    } else {
        console.log("TEST_RESULT:real-error-still-flagged:FAIL:expected error-line, got " + cls);
    }
}
DENO_SCRIPT
)

while IFS= read -r line; do
    case "$line" in
        TEST_RESULT:*) check_result "$line" ;;
    esac
done <<< "$OUTPUT"

# Summary
echo ""
echo "==============================================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
