#!/bin/bash
# Test for Issue #83: README disk threshold documentation matches code
# Verifies that README.md documents the correct disk warning/clear percentages

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Testing Issue #83: README disk threshold documentation"
echo "======================================================"
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

# Extract the actual code constants from dashboard.js using awk to get only the value
DISK_WARNING=$(awk '/DISK_WARNING_PERCENT:/ && !/CLEAR/' "$REPO_ROOT/docs/dashboard.js" | awk -F': ' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
DISK_CLEAR=$(awk '/DISK_WARNING_CLEAR_PERCENT:/' "$REPO_ROOT/docs/dashboard.js" | awk -F': ' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')

echo "Code constants: warning=${DISK_WARNING}%, clear=${DISK_CLEAR}%"
echo ""

# Test 1: README.md mentions the correct warning threshold
if grep -q "Disk usage under ${DISK_WARNING}%" "$REPO_ROOT/README.md"; then
    pass_test "README.md healthy threshold matches code (under ${DISK_WARNING}%)"
else
    fail_test "README.md healthy threshold does not mention 'under ${DISK_WARNING}%'"
fi

# Test 2: README.md mentions the correct warning trigger
if grep -q "Disk usage at or above ${DISK_WARNING}%" "$REPO_ROOT/README.md"; then
    pass_test "README.md warning trigger matches code (at or above ${DISK_WARNING}%)"
else
    fail_test "README.md warning trigger does not mention 'at or above ${DISK_WARNING}%'"
fi

# Test 3: README.md mentions the correct clear threshold
if grep -q "dropping to or below ${DISK_CLEAR}%" "$REPO_ROOT/README.md"; then
    pass_test "README.md clear threshold matches code (dropping to or below ${DISK_CLEAR}%)"
else
    fail_test "README.md clear threshold does not mention 'dropping to or below ${DISK_CLEAR}%'"
fi

# Test 4: README.md does NOT contain the old stale thresholds in the health classification section
if grep -q "Disk usage under 75%" "$REPO_ROOT/README.md"; then
    fail_test "README.md still contains stale 'Disk usage under 75%'"
else
    pass_test "README.md does not contain stale 75% healthy threshold"
fi

# Test 5: README.md mentions hysteresis behaviour between clear and warning thresholds
if grep -qi "hysteresis" "$REPO_ROOT/README.md"; then
    pass_test "README.md explains hysteresis behaviour"
else
    fail_test "README.md does not mention hysteresis behaviour"
fi

# Test 6: README.md explains the hysteresis band
if grep -q "${DISK_CLEAR}%" "$REPO_ROOT/README.md" && grep -q "${DISK_WARNING}%" "$REPO_ROOT/README.md"; then
    pass_test "README.md references both ${DISK_CLEAR}% and ${DISK_WARNING}% thresholds"
else
    fail_test "README.md missing one or both threshold values (${DISK_CLEAR}%/${DISK_WARNING}%)"
fi

echo ""
echo "======================================================"
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
