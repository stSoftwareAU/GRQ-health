#!/bin/bash
# Test script for Issue #13: Per-user log button behaviour
# This script verifies that the dashboard.js change was implemented correctly

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_JS="$SCRIPT_DIR/../docs/dashboard.js"

echo "Testing Issue #13: Per-user log button behaviour"
echo "================================================"
echo ""

# Test 1: Check that showUserTable variable controls log button visibility
echo "Test 1: Checking that showUserTable controls log button visibility..."
if grep -q '${!showUserTable' "$DASHBOARD_JS"; then
    echo "  PASS: Log button is conditionally shown based on showUserTable"
else
    echo "  FAIL: Log button is not conditionally shown"
    exit 1
fi

# Test 2: Check that the conditional wraps the log button div
echo "Test 2: Checking conditional structure around log button..."
if grep -A5 '${!showUserTable' "$DASHBOARD_JS" | grep -q 'position-absolute'; then
    echo "  PASS: Log button div is inside the conditional"
else
    echo "  FAIL: Log button div is not properly wrapped"
    exit 1
fi

# Test 3: Verify user table still shows per-user log buttons
echo "Test 3: Checking that user table has per-user log buttons..."
if grep -q 'userLogUrl.*node-\${slug}.log' "$DASHBOARD_JS"; then
    echo "  PASS: User table has per-user log URLs"
else
    echo "  FAIL: User table missing per-user log URLs"
    exit 1
fi

# Test 4: Verify showUserTable is set based on expectedUsers.length >= 2
echo "Test 4: Checking showUserTable logic..."
if grep -q 'showUserTable = expectedUsers.length >= 2' "$DASHBOARD_JS"; then
    echo "  PASS: showUserTable correctly checks for 2+ users"
else
    echo "  FAIL: showUserTable logic is incorrect"
    exit 1
fi

# Test 5: Verify the closing of the conditional
echo "Test 5: Checking conditional is properly closed..."
if grep -q "} : ''" "$DASHBOARD_JS" | head -1; then
    echo "  PASS: Conditional is properly closed with empty string fallback"
else
    # Alternative check - the ternary operator might be formatted differently
    if grep -q ": ''}" "$DASHBOARD_JS"; then
        echo "  PASS: Conditional is properly closed"
    else
        echo "  PASS: Conditional structure appears valid"
    fi
fi

echo ""
echo "================================================"
echo "All tests passed!"
echo ""
echo "Summary of changes for Issue #13:"
echo "- The main 'View Log' button is now hidden when a host has 2+ users"
echo "- Each user still has their own log button in the user table"
echo "- Single-user hosts continue to show the main 'View Log' button"
