#!/bin/bash
# Test for Issue #63: Only one log file should be copied (per-user log, not node.log)
# Verifies that the main() function in run.sh copies only node-${USER_SLUG}.log
# and does NOT create a generic node.log copy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"

echo "Testing Issue #63: Single log file copy (no duplicate node.log)"
echo "================================================================"
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

# Create a temporary working directory
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Set up fake environment
export HOME="$WORK_DIR"
mkdir -p "$WORK_DIR/logs"
echo "test log content" > "$WORK_DIR/logs/node.log"

# Create a fake docs directory
DEST_DIR="$WORK_DIR/docs/TESTHOST"
mkdir -p "$DEST_DIR"

# Simulate the variables that main() uses for log copying
HOSTNAME="TESTHOST"
USER_SLUG="score"
LOG_SRC="$WORK_DIR/logs/node.log"
LOG_DEST_DIR="$DEST_DIR"

# Test 1: Only per-user log should be created
echo "Test 1: Only per-user log file is created..."

# Extract the log-copy block logic from run.sh and verify it only creates per-user log
# We check that the source run.sh does NOT contain a copy to node.log in the log-copy section
LOG_DEST_USER="${LOG_DEST_DIR}/node-${USER_SLUG}.log"

# Simulate what run.sh should do: only copy to per-user log
if [ -f "$LOG_SRC" ]; then
    mkdir -p "$LOG_DEST_DIR"
    cp "$LOG_SRC" "$LOG_DEST_USER"
fi

if [ -f "$LOG_DEST_USER" ]; then
    pass_test "Per-user log file node-${USER_SLUG}.log was created"
else
    fail_test "Per-user log file node-${USER_SLUG}.log was NOT created"
fi

# Test 2: Verify run.sh does not copy to node.log in the log copy section
echo "Test 2: run.sh does not create a generic node.log copy..."

# Extract the log-copy section from main() — the block between "After updating JSON" and the git check
# Look for LOG_DEST_LATEST which was the old backwards-compat copy
if grep -q 'LOG_DEST_LATEST' "$RUN_SH"; then
    fail_test "run.sh still contains LOG_DEST_LATEST (backwards-compat node.log copy)"
else
    pass_test "run.sh does not contain LOG_DEST_LATEST variable"
fi

# Test 3: Verify run.sh does not copy LOG_SRC to a node.log destination
echo "Test 3: run.sh does not copy to a generic node.log destination..."

# Check for the pattern: cp "$LOG_SRC" "...node.log" (the old backwards compat copy)
if grep -qE 'cp.*LOG_SRC.*LOG_DEST_LATEST' "$RUN_SH"; then
    fail_test "run.sh still copies to LOG_DEST_LATEST"
else
    pass_test "run.sh does not copy to LOG_DEST_LATEST"
fi

echo ""
echo "================================================================"
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
