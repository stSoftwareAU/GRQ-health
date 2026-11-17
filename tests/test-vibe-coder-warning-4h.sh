#!/bin/bash
# Test for Issue #118: Vibe Coder must not be flagged before 4 hours
#
# Background: a Vibe Coder calls helpers/repos.sh roughly hourly, but a
# routine run (refining an issue, building, running tests) can quietly
# burn well over an hour before the next heartbeat. Flagging at 2h was
# too aggressive — a perfectly healthy worker was being highlighted while
# it was still mid-task. Issue #118 raises the warning threshold from
# 2h to 4h so a Vibe Coder stays 'healthy' for the first 4 hours, then
# 'warning', then dead at 8h (per Issue #112).
#
# This test enforces:
#   1. A 3h-stale Vibe Coder is still 'healthy' (was previously 'warning').
#   2. A 5h-stale Vibe Coder is 'warning' (past the new 4h threshold).
#   3. Every Vibe Coder entry in docs/repos.json has warning_hours = 4.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #118: Vibe Coder warning threshold raised to 4h"
echo "============================================================="
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
# Test 1: 3h-stale Vibe Coder is healthy under the new 4h warning
# ============================================================
echo "Test 1: Vibe Coder at 3h stays healthy (under new 4h warning)..."

run_and_check "vibe-healthy-3h" "
    const now = ${NOW};
    const repo = {
        name: 'Vibe Coder:GRQ-23',
        last_commit_ts: now - (3 * 60 * 60),  // 3 hours ago
        warning_hours: 4,
        error_hours: 8
    };
    const status = getRepoStatus(repo, now);
    if (status === 'healthy') {
        console.log('TEST_RESULT:vibe-healthy-3h:PASS:3h still healthy (under 4h)');
    } else {
        console.log('TEST_RESULT:vibe-healthy-3h:FAIL:expected healthy, got ' + status);
    }
"

# ============================================================
# Test 2: 5h-stale Vibe Coder crosses the new 4h warning
# ============================================================
echo ""
echo "Test 2: Vibe Coder at 5h is warning (past 4h, before 8h dead)..."

run_and_check "vibe-warning-5h" "
    const now = ${NOW};
    const repo = {
        name: 'Vibe Coder:GRQ-23',
        last_commit_ts: now - (5 * 60 * 60),  // 5 hours ago
        warning_hours: 4,
        error_hours: 8
    };
    const status = getRepoStatus(repo, now);
    if (status === 'warning') {
        console.log('TEST_RESULT:vibe-warning-5h:PASS:5h is warning');
    } else {
        console.log('TEST_RESULT:vibe-warning-5h:FAIL:expected warning, got ' + status);
    }
"

# ============================================================
# Test 3: All Vibe Coder entries in repos.json have warning_hours = 4
# ============================================================
echo ""
echo "Test 3: repos.json Vibe Coder entries have warning_hours = 4..."

REPOS_JSON="$SCRIPT_DIR/../docs/repos.json"
if command -v jq &> /dev/null && [ -f "$REPOS_JSON" ]; then
    BAD=0
    while IFS=$'\t' read -r name warning_hours; do
        if [ "$warning_hours" = "4" ]; then
            pass_test "$name has warning_hours=4"
        else
            fail_test "$name has warning_hours=$warning_hours, expected 4"
            BAD=$((BAD + 1))
        fi
    done < <(jq -r '.repos[] | select(.name | startswith("Vibe Coder")) | [.name, .warning_hours] | @tsv' "$REPOS_JSON")
    if [ "$BAD" -gt 0 ]; then
        fail_test "$BAD Vibe Coder entries do not have warning_hours=4"
    fi
else
    echo "  SKIP: jq not available or repos.json not found"
fi

echo ""
echo "============================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
