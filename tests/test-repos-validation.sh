#!/bin/bash
# Test for Issue #36 / #43: Input validation in repos.sh
# Verifies that repos.sh rejects invalid repo names and accepts valid ones
# Issue #43: Repo names with spaces are valid (e.g., "Training Data")

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

# Test 1: Valid repo names should be accepted
echo "Test 1: Valid repo names..."
for name in "Dividends" "FX" "share-prices" "my_repo" "repo.2025" \
            "org/repo" "host:path" "repo+extra" "A" "a1b2c3" \
            "Training Data" "S3 Sync" "Company Reports" "Discovery Snapshot" \
            "Scorer:client:luke"; do
    if bash "$REPOS_SCRIPT" --validate "$name" 2>/dev/null; then
        pass_test "accepted valid name: $name"
    else
        fail_test "rejected valid name: $name"
    fi
done

# Test 2: Invalid repo names should be rejected (special characters)
echo "Test 2: Invalid repo names (special characters)..."
for name in '<script>' '"; rm -rf /' '$HOME' 'a&b' 'x|y'; do
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

# Test 4: Command injection attempts should be rejected
echo "Test 4: Command injection attempts..."
for name in '$(whoami)' '`id`' 'repo;ls' 'repo$(cat /etc/passwd)' \
            'repo`rm -rf /`' '{evil}' 'a\\nb'; do
    if bash "$REPOS_SCRIPT" --validate "$name" 2>/dev/null; then
        fail_test "accepted injection attempt: $name"
    else
        pass_test "rejected injection attempt: $name"
    fi
done

# Test 5: Error messages should go to stderr
echo "Test 5: Error output goes to stderr..."
STDERR_OUTPUT=$(bash "$REPOS_SCRIPT" --validate '$(evil)' 2>&1 1>/dev/null || true)
if [[ "$STDERR_OUTPUT" == *"Error: Invalid repo name"* ]]; then
    pass_test "error message sent to stderr for invalid name"
else
    fail_test "error message not on stderr, got: $STDERR_OUTPUT"
fi

STDERR_EMPTY=$(bash "$REPOS_SCRIPT" --validate "" 2>&1 1>/dev/null || true)
if [[ "$STDERR_EMPTY" == *"Error: Repo name cannot be empty"* ]]; then
    pass_test "error message sent to stderr for empty name"
else
    fail_test "error message not on stderr for empty name, got: $STDERR_EMPTY"
fi

# Test 6: Missing argument for --validate should fail
echo "Test 6: Missing --validate argument..."
if bash "$REPOS_SCRIPT" --validate 2>/dev/null; then
    fail_test "accepted --validate without repo name"
else
    pass_test "rejected --validate without repo name"
fi

# Test 7: All names in docs/repos.json must pass validation (Issue #43)
echo "Test 7: All repo names from docs/repos.json..."
REPOS_JSON="$SCRIPT_DIR/../docs/repos.json"
if command -v jq &> /dev/null && [ -f "$REPOS_JSON" ]; then
    while IFS= read -r repo_name; do
        if bash "$REPOS_SCRIPT" --validate "$repo_name" 2>/dev/null; then
            pass_test "repos.json name accepted: $repo_name"
        else
            fail_test "repos.json name rejected: $repo_name"
        fi
    done < <(jq -r '.repos[].name' "$REPOS_JSON")
else
    echo "  SKIP: jq not available or repos.json not found"
fi

echo ""
echo "=============================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
