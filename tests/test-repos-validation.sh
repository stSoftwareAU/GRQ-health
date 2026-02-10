#!/bin/bash
# Test for Issue #36: Input validation in repos.sh
# Verifies that repos.sh rejects invalid repo names

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_SCRIPT="$SCRIPT_DIR/../helpers/repos.sh"

echo "Testing Issue #36: Repo name input validation"
echo "=============================================="
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

# Test 1: Valid repo names should be accepted (exit code indicates format OK)
# We use --dry-run to test validation without actually modifying files
echo "Test 1: Valid repo names..."
for name in "Dividends" "FX" "share-prices" "my_repo" "repo.2025"; do
    if bash "$REPOS_SCRIPT" --validate "$name" 2>/dev/null; then
        pass_test "accepted valid name: $name"
    else
        fail_test "rejected valid name: $name"
    fi
done

# Test 2: Invalid repo names should be rejected
echo "Test 2: Invalid repo names..."
for name in '<script>' '"; rm -rf /' '$HOME' 'repo name' 'a&b' 'x|y'; do
    if bash "$REPOS_SCRIPT" --validate "$name" 2>/dev/null; then
        fail_test "accepted invalid name: $name"
    else
        pass_test "rejected invalid name: $name"
    fi
done

# Test 3: Empty name should be rejected
echo "Test 3: Empty repo name..."
if bash "$REPOS_SCRIPT" --validate "" 2>/dev/null; then
    fail_test "accepted empty name"
else
    pass_test "rejected empty name"
fi

echo ""
echo "=============================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
