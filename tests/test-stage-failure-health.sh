#!/bin/bash
# Test for Issue #127: [stage-failure-health] is the authoritative success/failure signal
#
# Background: GRQ now emits a deterministic line:
#   [stage-failure-health] failures=N firstStage=S firstExitCode=C firstHitLine=L
# The consumer (scan_log_errors in run.sh) must trust this line over noisy
# "Task failed with status N" reporting-layer messages. See GRQ#2387.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"

echo "Testing Issue #127: [stage-failure-health] authoritative classifier"
echo "==================================================================="
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

# Extract scan_log_errors from run.sh
eval "$(sed -n '/^scan_log_errors()/,/^}/p' "$RUN_SH")"

HOME="$WORK_DIR"
mkdir -p "$WORK_DIR/logs"
# shellcheck disable=SC2034
NODE_PID=""

# ---------------------------------------------------------------------------
# Test 1: GRQ-3-sloth.log misclassification scenario from GRQ#2387
# Authoritative line says failures=0, but noisy "Task failed with status 2"
# follows. Result MUST be classified as successful (exception_count=0).
# ---------------------------------------------------------------------------
echo "Test 1: failures=0 followed by 'Task failed with status 2' classifies as success..."
cat > "$WORK_DIR/logs/node.log" << 'EOF'
[2026-05-18 06:26:35 AEST] Discovery loop completed after 2 iteration(s) in 5642s
[wasm-activation-health] failures=0 firstUuid=none firstStage=none
[stage-failure-health] failures=0 firstStage=none firstExitCode=0 firstHitLine=0
Task failed with status 2 at 2026-05-18 02:29:37 AEST [option=discoveryReplay]
EOF

scan_log_errors
# shellcheck disable=SC2154
if [ "$exception_count" -eq 0 ]; then
    pass_test "GRQ-3-sloth.log fixture classified as success (count=$exception_count)"
else
    # shellcheck disable=SC2154
    fail_test "GRQ-3-sloth.log fixture falsely flagged: $exception_summary"
fi

# ---------------------------------------------------------------------------
# Test 2: failures>0 must be classified as failed with surfaced metadata
# ---------------------------------------------------------------------------
echo "Test 2: failures=3 is classified as failed with stage metadata..."
cat > "$WORK_DIR/logs/node.log" << 'EOF'
Some normal log output
[stage-failure-health] failures=3 firstStage=discoveryReplay firstExitCode=42 firstHitLine=1234
Task completed
EOF

scan_log_errors
if [ "$exception_count" -eq 3 ]; then
    pass_test "failures=3 surfaced as exception_count=3"
else
    fail_test "failures=3 not surfaced correctly (count=$exception_count)"
fi

# shellcheck disable=SC2154
if echo "$exception_summary" | grep -q "discoveryReplay"; then
    pass_test "failure summary names firstStage (summary=$exception_summary)"
else
    fail_test "failure summary missing firstStage: $exception_summary"
fi

if echo "$exception_summary" | grep -q "42"; then
    pass_test "failure summary names firstExitCode (summary=$exception_summary)"
else
    fail_test "failure summary missing firstExitCode: $exception_summary"
fi

# ---------------------------------------------------------------------------
# Test 3: [reporting-warning] lines surface separately, not as failures
# ---------------------------------------------------------------------------
echo "Test 3: [reporting-warning] is counted separately and does not fail the run..."
cat > "$WORK_DIR/logs/node.log" << 'EOF'
[reporting-warning] transient git push retry succeeded after 2 attempts
[reporting-warning] could not record run health
[stage-failure-health] failures=0 firstStage=none firstExitCode=0 firstHitLine=0
EOF

scan_log_errors
if [ "$exception_count" -eq 0 ]; then
    pass_test "reporting-warning present, failures=0 → success (count=$exception_count)"
else
    fail_test "reporting-warning falsely flagged as failure: $exception_summary"
fi

# shellcheck disable=SC2154
if [ "${reporting_warning_count:-0}" -eq 2 ]; then
    pass_test "reporting_warning_count=2 surfaced (got $reporting_warning_count)"
else
    fail_test "reporting_warning_count expected 2, got ${reporting_warning_count:-unset}"
fi

# ---------------------------------------------------------------------------
# Test 4: Legacy logs (no [stage-failure-health]) keep the existing classifier
# ---------------------------------------------------------------------------
echo "Test 4: Legacy log with stack trace still detected as error..."
cat > "$WORK_DIR/logs/node.log" << 'EOF'
2026-03-07T10:35:47.452Z [INFO] Starting process
Error: Something went wrong
    at Object.runInContext (vm.js:130:16)
    at main (index.js:52:8)
EOF

scan_log_errors
if [ "$exception_count" -gt 0 ]; then
    pass_test "Legacy stack trace still detected (count=$exception_count)"
else
    fail_test "Legacy stack trace NOT detected — fall-back broken"
fi

# ---------------------------------------------------------------------------
# Test 5: Legacy clean log (no [stage-failure-health]) classifies as success
# ---------------------------------------------------------------------------
echo "Test 5: Legacy clean log still classifies as success..."
cat > "$WORK_DIR/logs/node.log" << 'EOF'
run_core pid=20689 start=Sat Mar  7 21:30:59 AEDT 2026
Version 1.3.14
HEAD is now at 8f0cfaf Evolution score 0.4065 -> 0.4066
EOF

scan_log_errors
if [ "$exception_count" -eq 0 ]; then
    pass_test "Legacy clean log classified as success (count=$exception_count)"
else
    fail_test "Legacy clean log falsely flagged: $exception_summary"
fi

# ---------------------------------------------------------------------------
# Test 6: failures=0 with a ⚠️ warning in the noise is still success
# (authoritative line overrides legacy emoji counts)
# ---------------------------------------------------------------------------
echo "Test 6: failures=0 overrides ⚠️ emoji legacy counts..."
cat > "$WORK_DIR/logs/node.log" << 'EOF'
some stage emitted ⚠️ a non-critical warning
[stage-failure-health] failures=0 firstStage=none firstExitCode=0 firstHitLine=0
EOF

scan_log_errors
if [ "$exception_count" -eq 0 ]; then
    pass_test "⚠️ noise ignored when failures=0 (count=$exception_count)"
else
    fail_test "⚠️ noise falsely flagged despite failures=0: $exception_summary"
fi

# Summary
echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
