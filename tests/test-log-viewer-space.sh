#!/bin/bash
# Test script for Issue #18: Log viewer space optimisation
# This script verifies that the CSS changes reduce wasted space

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_VIEWER="$SCRIPT_DIR/../docs/log-viewer.html"

echo "Testing Issue #18: Log viewer space optimisation"
echo "================================================="
echo ""

# Test 1: Check that .log-container has reduced padding (10px or less)
echo "Test 1: Checking .log-container padding..."
PADDING=$(grep -A20 '\.log-container {' "$LOG_VIEWER" | grep 'padding:' | head -1 | sed 's/.*padding:\s*\([^;]*\).*/\1/')
if [ -n "$PADDING" ]; then
    # Extract the numeric value (first number in the padding)
    PADDING_VALUE=$(echo "$PADDING" | grep -oE '[0-9]+' | head -1)
    if [ "$PADDING_VALUE" -le 10 ]; then
        echo "  PASS: .log-container padding is ${PADDING_VALUE}px (≤ 10px)"
    else
        echo "  FAIL: .log-container padding is ${PADDING_VALUE}px (should be ≤ 10px)"
        exit 1
    fi
else
    echo "  FAIL: Could not find .log-container padding"
    exit 1
fi

# Test 2: Check that .log-container has reduced margin (top should be ≤ 50px)
echo "Test 2: Checking .log-container margin..."
MARGIN=$(grep -A20 '\.log-container {' "$LOG_VIEWER" | grep 'margin:' | head -1 | sed 's/.*margin:\s*\([^;]*\).*/\1/')
if [ -n "$MARGIN" ]; then
    # Extract the first number (top margin)
    TOP_MARGIN=$(echo "$MARGIN" | grep -oE '[0-9]+' | head -1)
    if [ "$TOP_MARGIN" -le 50 ]; then
        echo "  PASS: .log-container top margin is ${TOP_MARGIN}px (≤ 50px)"
    else
        echo "  FAIL: .log-container top margin is ${TOP_MARGIN}px (should be ≤ 50px)"
        exit 1
    fi
else
    echo "  FAIL: Could not find .log-container margin"
    exit 1
fi

# Test 3: Check that .log-content has reduced padding (12px or less)
echo "Test 3: Checking .log-content padding..."
CONTENT_PADDING=$(grep -A20 '\.log-content {' "$LOG_VIEWER" | grep 'padding:' | head -1 | sed 's/.*padding:\s*\([^;]*\).*/\1/')
if [ -n "$CONTENT_PADDING" ]; then
    # Extract the numeric value
    CONTENT_PADDING_VALUE=$(echo "$CONTENT_PADDING" | grep -oE '[0-9]+' | head -1)
    if [ "$CONTENT_PADDING_VALUE" -le 12 ]; then
        echo "  PASS: .log-content padding is ${CONTENT_PADDING_VALUE}px (≤ 12px)"
    else
        echo "  FAIL: .log-content padding is ${CONTENT_PADDING_VALUE}px (should be ≤ 12px)"
        exit 1
    fi
else
    echo "  FAIL: Could not find .log-content padding"
    exit 1
fi

# Test 4: Check that line-height is compact (1.3 or less)
echo "Test 4: Checking .log-content line-height..."
LINE_HEIGHT=$(grep -A20 '\.log-content {' "$LOG_VIEWER" | grep 'line-height:' | head -1 | sed 's/.*line-height:\s*\([^;]*\).*/\1/')
if [ -n "$LINE_HEIGHT" ]; then
    # Compare as integer after multiplying by 10 to handle decimals
    LINE_HEIGHT_INT=$(echo "$LINE_HEIGHT" | awk '{printf "%.0f", $1 * 10}')
    if [ "$LINE_HEIGHT_INT" -le 13 ]; then
        echo "  PASS: .log-content line-height is ${LINE_HEIGHT} (≤ 1.3)"
    else
        echo "  FAIL: .log-content line-height is ${LINE_HEIGHT} (should be ≤ 1.3)"
        exit 1
    fi
else
    echo "  FAIL: Could not find .log-content line-height"
    exit 1
fi

# Test 5: Check that .log-header padding is compact (8px or less)
echo "Test 5: Checking .log-header padding..."
HEADER_PADDING=$(grep -A20 '\.log-header {' "$LOG_VIEWER" | grep 'padding:' | head -1 | sed 's/.*padding:\s*\([^;]*\).*/\1/')
if [ -n "$HEADER_PADDING" ]; then
    # Extract the numeric value (first number)
    HEADER_PADDING_VALUE=$(echo "$HEADER_PADDING" | grep -oE '[0-9]+' | head -1)
    if [ "$HEADER_PADDING_VALUE" -le 8 ]; then
        echo "  PASS: .log-header padding is ${HEADER_PADDING_VALUE}px (≤ 8px)"
    else
        echo "  FAIL: .log-header padding is ${HEADER_PADDING_VALUE}px (should be ≤ 8px)"
        exit 1
    fi
else
    echo "  FAIL: Could not find .log-header padding"
    exit 1
fi

# Test 6: Check that side margins are compact (10px or less)
echo "Test 6: Checking .log-container side margins..."
# Extract all margin numbers
MARGIN_VALUES=$(echo "$MARGIN" | grep -oE '[0-9]+')
# Get the second value (right margin) or first if only one value
SECOND_MARGIN=$(echo "$MARGIN_VALUES" | sed -n '2p')
if [ -z "$SECOND_MARGIN" ]; then
    SECOND_MARGIN=$(echo "$MARGIN_VALUES" | head -1)
fi
if [ "$SECOND_MARGIN" -le 10 ]; then
    echo "  PASS: .log-container side margin is ${SECOND_MARGIN}px (≤ 10px)"
else
    echo "  FAIL: .log-container side margin is ${SECOND_MARGIN}px (should be ≤ 10px)"
    exit 1
fi

echo ""
echo "================================================="
echo "All tests passed!"
echo ""
echo "Summary of fix for Issue #18:"
echo "- Reduced .log-container padding from 20px to 10px or less"
echo "- Reduced .log-container margins (top from 80px, sides from 20px)"
echo "- Reduced .log-content padding from 20px to 12px or less"
echo "- Reduced line-height from 1.4 to 1.3 or less"
echo "- Reduced .log-header padding for compactness"
echo "- More log content is now visible without scrolling"
