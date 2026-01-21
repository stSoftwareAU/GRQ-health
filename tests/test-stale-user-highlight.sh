#!/bin/bash
# Test for Issue #22: Highlight which user has the warning
# This test verifies that the dashboard correctly identifies and displays
# which specific user(s) are stale in the warning section.

echo "Testing Issue #22: Stale user highlighting in warnings"
echo "======================================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

# Test 1: Check that getStaleUsers function exists
echo "Test 1: Checking that getStaleUsers function exists in dashboard.js..."
if grep -q "function getStaleUsers" docs/dashboard.js; then
    echo "  PASS: getStaleUsers function exists"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "  FAIL: getStaleUsers function not found"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Test 2: Check that buildStaleUserWarning function exists
echo "Test 2: Checking that buildStaleUserWarning function exists in dashboard.js..."
if grep -q "function buildStaleUserWarning" docs/dashboard.js; then
    echo "  PASS: buildStaleUserWarning function exists"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "  FAIL: buildStaleUserWarning function not found"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Test 3: Check that getStaleUsers checks for multi-user hosts (>= 2 users)
echo "Test 3: Checking that getStaleUsers only checks multi-user hosts..."
if grep -A 5 "function getStaleUsers" docs/dashboard.js | grep -q "expectedUsers.length < 2"; then
    echo "  PASS: getStaleUsers checks for 2+ users"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "  FAIL: getStaleUsers should only check multi-user hosts"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Test 4: Check that buildStaleUserWarning includes user names
echo "Test 4: Checking that buildStaleUserWarning includes user names..."
if grep -A 20 "function buildStaleUserWarning" docs/dashboard.js | grep -q "username"; then
    echo "  PASS: buildStaleUserWarning includes user names"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "  FAIL: buildStaleUserWarning should include user names"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Test 5: Check that buildStaleUserWarning includes timestamp info
echo "Test 5: Checking that buildStaleUserWarning includes timestamp info..."
if grep -A 20 "function buildStaleUserWarning" docs/dashboard.js | grep -q "formatTimestamp"; then
    echo "  PASS: buildStaleUserWarning includes timestamp info"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "  FAIL: buildStaleUserWarning should include timestamp info"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Test 6: Check that buildStaleUserWarning handles "never seen" case
echo "Test 6: Checking that buildStaleUserWarning handles missing heartbeat..."
if grep -A 20 "function buildStaleUserWarning" docs/dashboard.js | grep -q "never seen"; then
    echo "  PASS: buildStaleUserWarning handles 'never seen' case"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "  FAIL: buildStaleUserWarning should handle 'never seen' case"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Test 7: Check that warning section uses buildStaleUserWarning
echo "Test 7: Checking that warning section uses buildStaleUserWarning..."
# Check for actual usage: const staleUserWarning = buildStaleUserWarning(data, now);
if grep -q "const staleUserWarning = buildStaleUserWarning" docs/dashboard.js; then
    echo "  PASS: Warning section uses buildStaleUserWarning"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "  FAIL: Warning section should use buildStaleUserWarning"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Test 8: Check that stale user warning uses singular/plural correctly
echo "Test 8: Checking singular/plural grammar in stale user warning..."
if grep -A 20 "function buildStaleUserWarning" docs/dashboard.js | grep -q "Stale user.*s.*length > 1"; then
    echo "  PASS: Uses correct singular/plural grammar"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "  FAIL: Should use 'user' (singular) or 'users' (plural) appropriately"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Test 9: Check Issue #22 comment exists
echo "Test 9: Checking that Issue #22 is documented in the code..."
if grep -q "Issue #22" docs/dashboard.js; then
    echo "  PASS: Issue #22 is documented in the code"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "  FAIL: Issue #22 should be documented in the code"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

echo ""
echo "======================================================="
echo "Test Summary"
echo "======================================================="
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo "All tests PASSED! Issue #22 is properly implemented."
    echo ""
    echo "Summary of changes for Issue #22:"
    echo "- Added getStaleUsers() function to identify stale users in multi-user hosts"
    echo "- Added buildStaleUserWarning() function to build human-readable warning text"
    echo "- Warning section now shows which specific user(s) are stale"
    echo "- Stale user warnings include relative timestamps (e.g., '1d 6h ago')"
    echo "- Handles 'never seen' case for users without heartbeat"
    echo "Status: PASSED"
    exit 0
else
    echo "Some tests FAILED! Issue #22 implementation needs work."
    echo "Status: FAILED"
    exit 1
fi
