#!/bin/bash
# Test for Issue #112: Vibe Coder should be marked dead after 8 hours
#
# The Vibe Coder calls helpers/repos.sh frequently while it is alive; the
# rate limit means the heartbeat is bumped at most once per hour. So if the
# heartbeat is more than 8 hours old, the worker is dead and the dashboard
# should classify the repo as 'error'.
#
# This test enforces:
#   1. getRepoStatus marks a Vibe Coder as 'error' once the heartbeat is
#      older than 8 hours.
#   2. A Vibe Coder with a 7-hour-old heartbeat is still 'warning', not
#      'error' — confirming the threshold is at 8h, not earlier.
#   3. Every Vibe Coder entry in docs/repos.json has error_hours = 8.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #112: Vibe Coder marked dead after 8 hours"
echo "========================================================"
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

run_and_check() {
    local test_name="$1"
    local js_code="$2"
    local output
    output=$(run_js_test "$js_code" 2>&1) || true
    local result
    result=$(echo "$output" | grep "^TEST_RESULT:${test_name}:" | head -1)
    if [[ "$result" == *":PASS:"* ]]; then
        local detail
        detail=$(echo "$result" | cut -d: -f4-)
        pass_test "$test_name: $detail"
    else
        local detail
        detail=$(echo "$result" | cut -d: -f4-)
        if [ -z "$detail" ]; then
            detail="no output (full: $output)"
        fi
        fail_test "$test_name: $detail"
    fi
}

NOW=1773014400  # Mon 2026-03-09 00:00 UTC

# ============================================================
# Test 1: 9h-stale Vibe Coder is error (past 8h dead threshold)
# ============================================================
echo "Test 1: Vibe Coder past 8h is error..."

run_and_check "vibe-dead-9h" "
    const now = ${NOW};
    const repo = {
        name: 'Vibe Coder:GRQ-23',
        last_commit_ts: now - (9 * 60 * 60),  // 9 hours ago
        warning_hours: 4,
        error_hours: 8
    };
    const status = getRepoStatus(repo, now);
    if (status === 'error') {
        console.log('TEST_RESULT:vibe-dead-9h:PASS:9h > 8h error');
    } else {
        console.log('TEST_RESULT:vibe-dead-9h:FAIL:expected error, got ' + status);
    }
"

# ============================================================
# Test 2: 7h-stale Vibe Coder is still warning, not error
# ============================================================
echo ""
echo "Test 2: Vibe Coder at 7h still warning, not yet dead..."

run_and_check "vibe-warning-7h" "
    const now = ${NOW};
    const repo = {
        name: 'Vibe Coder:GRQ-23',
        last_commit_ts: now - (7 * 60 * 60),  // 7 hours ago
        warning_hours: 4,
        error_hours: 8
    };
    const status = getRepoStatus(repo, now);
    if (status === 'warning') {
        console.log('TEST_RESULT:vibe-warning-7h:PASS:7h still warning (not yet 8h dead)');
    } else {
        console.log('TEST_RESULT:vibe-warning-7h:FAIL:expected warning, got ' + status);
    }
"

# ============================================================
# Test 3: All Vibe Coder entries in repos.json have error_hours = 8
# ============================================================
echo ""
echo "Test 3: repos.json Vibe Coder entries have error_hours = 8..."

REPOS_JSON="$SCRIPT_DIR/../docs/repos.json"
if command -v jq &> /dev/null && [ -f "$REPOS_JSON" ]; then
    BAD=0
    while IFS=$'\t' read -r name error_hours; do
        if [ "$error_hours" = "8" ]; then
            pass_test "$name has error_hours=8"
        else
            fail_test "$name has error_hours=$error_hours, expected 8"
            BAD=$((BAD + 1))
        fi
    done < <(jq -r '.repos[] | select(.name | startswith("Vibe Coder")) | [.name, .error_hours] | @tsv' "$REPOS_JSON")
    if [ "$BAD" -gt 0 ]; then
        fail_test "$BAD Vibe Coder entries do not have error_hours=8"
    fi
else
    echo "  SKIP: jq not available or repos.json not found"
fi

echo ""
echo "========================================================"
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
