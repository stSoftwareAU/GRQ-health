#!/bin/bash
# Test script for Issue #17: Status badge overflow fix
#
# These tests verify that the CSS properties needed to prevent the health-status
# badge from overflowing host cards are present with correct values. They parse
# actual CSS property values from styles.css and assert on them.
#
# Key behaviour under test:
# - .host-card must have overflow: hidden to clip overflow
# - .health-status must have flex-shrink: 0 to prevent shrinking
# - .health-status must have white-space: nowrap to prevent wrapping
# - .host-card h5 must have min-width: 0 for proper flex truncation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STYLES_CSS="$SCRIPT_DIR/../docs/styles.css"

echo "Testing Issue #17: Status badge overflow fix"
echo "============================================="
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

# Helper: extract a CSS property value from a selector block in the CSS file.
# Usage: extract_css_value "selector" "property" "file"
# Returns the value (without the trailing semicolon) on stdout.
extract_css_value() {
    local selector="$1"
    local property="$2"
    local file="$3"
    # Find lines after the selector and extract the property value
    sed -n "/${selector//\./\\.}/,/}/p" "$file" | grep "$property:" | head -1 | sed "s/.*${property}:[[:space:]]*\([^;]*\).*/\1/" | tr -d ' '
}

# Test 1: .host-card has overflow: hidden
echo "Test 1: Checking .host-card has overflow: hidden..."
VALUE=$(extract_css_value ".host-card {" "overflow" "$STYLES_CSS")
if [ "$VALUE" = "hidden" ]; then
    pass_test ".host-card has overflow: hidden"
else
    fail_test ".host-card overflow is '$VALUE', expected 'hidden'"
fi

# Test 2: .health-status has flex-shrink: 0
echo "Test 2: Checking .health-status has flex-shrink: 0..."
VALUE=$(extract_css_value ".health-status {" "flex-shrink" "$STYLES_CSS")
if [ "$VALUE" = "0" ]; then
    pass_test ".health-status has flex-shrink: 0"
else
    fail_test ".health-status flex-shrink is '$VALUE', expected '0'"
fi

# Test 3: .health-status has white-space: nowrap
echo "Test 3: Checking .health-status has white-space: nowrap..."
VALUE=$(extract_css_value ".health-status {" "white-space" "$STYLES_CSS")
if [ "$VALUE" = "nowrap" ]; then
    pass_test ".health-status has white-space: nowrap"
else
    fail_test ".health-status white-space is '$VALUE', expected 'nowrap'"
fi

# Test 4: .host-card h5 has min-width: 0
echo "Test 4: Checking .host-card h5 has min-width: 0..."
VALUE=$(extract_css_value ".host-card h5 {" "min-width" "$STYLES_CSS")
if [ "$VALUE" = "0" ]; then
    pass_test ".host-card h5 has min-width: 0"
else
    fail_test ".host-card h5 min-width is '$VALUE', expected '0'"
fi

# Test 5: .host-card h5 has text-overflow: ellipsis
echo "Test 5: Checking .host-card h5 has text-overflow: ellipsis..."
VALUE=$(extract_css_value ".host-card h5 {" "text-overflow" "$STYLES_CSS")
if [ "$VALUE" = "ellipsis" ]; then
    pass_test ".host-card h5 has text-overflow: ellipsis"
else
    fail_test ".host-card h5 text-overflow is '$VALUE', expected 'ellipsis'"
fi

echo ""
echo "============================================="
echo "Test Summary"
echo "============================================="
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "Some tests FAILED."
    exit 1
else
    echo "All tests PASSED!"
    exit 0
fi
