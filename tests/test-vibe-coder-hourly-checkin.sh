#!/bin/bash
# Test for Issue #105: Vibe Coders should check in every hour or so
# Verifies that getRepoStatus supports hour-based thresholds via
# warning_hours and error_hours, so dead Vibe Coders are detected
# within hours rather than waiting ~24h for the day-grain check.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #105: Hour-based thresholds for Vibe Coders"
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

# Anchor timestamp: arbitrary "now" in the test universe.
NOW=1773014400  # Mon 2026-03-09 00:00 UTC

# ============================================================
# Test 1: Vibe Coder healthy when last commit is under warning_hours
# ============================================================
echo "Test 1: Vibe Coder healthy within warning_hours window..."

run_and_check "vibe-healthy-recent" "
    const now = ${NOW};
    const repo = {
        name: 'Vibe Coder:GRQ-23',
        last_commit_ts: now - (60 * 60),  // 1 hour ago
        warning_hours: 2,
        error_hours: 4
    };
    const status = getRepoStatus(repo, now);
    if (status === 'healthy') {
        console.log('TEST_RESULT:vibe-healthy-recent:PASS:1h ago < 2h warning is healthy');
    } else {
        console.log('TEST_RESULT:vibe-healthy-recent:FAIL:expected healthy, got ' + status);
    }
"

# ============================================================
# Test 2: Vibe Coder warning when between warning_hours and error_hours
# ============================================================
echo ""
echo "Test 2: Vibe Coder warning past warning_hours..."

run_and_check "vibe-warning-3h" "
    const now = ${NOW};
    const repo = {
        name: 'Vibe Coder:GRQ-23',
        last_commit_ts: now - (3 * 60 * 60),  // 3 hours ago
        warning_hours: 2,
        error_hours: 4
    };
    const status = getRepoStatus(repo, now);
    if (status === 'warning') {
        console.log('TEST_RESULT:vibe-warning-3h:PASS:3h > 2h warning, < 4h error');
    } else {
        console.log('TEST_RESULT:vibe-warning-3h:FAIL:expected warning, got ' + status);
    }
"

# ============================================================
# Test 3: Vibe Coder error past error_hours
# ============================================================
echo ""
echo "Test 3: Vibe Coder error past error_hours..."

run_and_check "vibe-error-5h" "
    const now = ${NOW};
    const repo = {
        name: 'Vibe Coder:GRQ-23',
        last_commit_ts: now - (5 * 60 * 60),  // 5 hours ago
        warning_hours: 2,
        error_hours: 4
    };
    const status = getRepoStatus(repo, now);
    if (status === 'error') {
        console.log('TEST_RESULT:vibe-error-5h:PASS:5h > 4h error');
    } else {
        console.log('TEST_RESULT:vibe-error-5h:FAIL:expected error, got ' + status);
    }
"

# ============================================================
# Test 4: Dead Vibe Coder (24h stale) is error, not healthy
# ============================================================
# This is the bug from issue #105 — dead workers were showing healthy
# because the default 1-business-day warning threshold was too generous.
echo ""
echo "Test 4: 24h-stale Vibe Coder is error, not healthy..."

run_and_check "vibe-dead-24h" "
    const now = ${NOW};
    const repo = {
        name: 'Vibe Coder:GRQ-25',
        last_commit_ts: now - (24 * 60 * 60),  // 24 hours ago
        warning_hours: 2,
        error_hours: 4
    };
    const status = getRepoStatus(repo, now);
    if (status === 'error') {
        console.log('TEST_RESULT:vibe-dead-24h:PASS:dead worker after 24h flagged as error');
    } else {
        console.log('TEST_RESULT:vibe-dead-24h:FAIL:expected error, got ' + status);
    }
"

# ============================================================
# Test 5: warning_hours alone (error_hours falls back to default conversion)
# ============================================================
echo ""
echo "Test 5: warning_hours alone uses default error threshold..."

run_and_check "vibe-warning-hours-only" "
    const now = ${NOW};
    const repo = {
        name: 'Vibe Coder:partial',
        last_commit_ts: now - (3 * 60 * 60),  // 3 hours ago
        warning_hours: 2
    };
    const status = getRepoStatus(repo, now);
    // warning_hours: 2 set, no error_hours — use warning_hours but
    // default error remains, so 3h > 2h warning is at minimum 'warning'.
    if (status === 'warning' || status === 'error') {
        console.log('TEST_RESULT:vibe-warning-hours-only:PASS:3h past 2h warning gives ' + status);
    } else {
        console.log('TEST_RESULT:vibe-warning-hours-only:FAIL:expected warning/error, got ' + status);
    }
"

# ============================================================
# Test 6: Hour thresholds override day thresholds when both are set
# ============================================================
echo ""
echo "Test 6: warning_hours/error_hours override warning_days/error_days..."

run_and_check "vibe-hours-override-days" "
    const now = ${NOW};
    const repo = {
        name: 'Vibe Coder:override',
        last_commit_ts: now - (5 * 60 * 60),  // 5 hours ago
        warning_days: 1,
        error_days: 2,
        warning_hours: 2,
        error_hours: 4
    };
    const status = getRepoStatus(repo, now);
    // 5h > 4h error_hours → error.
    // (If days were used, 5h ~= 0.21 days, well under 1-day warning → healthy.)
    if (status === 'error') {
        console.log('TEST_RESULT:vibe-hours-override-days:PASS:hour thresholds win');
    } else {
        console.log('TEST_RESULT:vibe-hours-override-days:FAIL:expected error, got ' + status);
    }
"

# ============================================================
# Test 7: Backward compatibility — repos without hour fields unaffected
# ============================================================
echo ""
echo "Test 7: Non-Vibe repos with day thresholds unchanged..."

run_and_check "day-thresholds-unchanged" "
    const now = ${NOW};
    const repo = {
        name: 'Dividends',
        last_commit_ts: now - (12 * 60 * 60),  // 12 hours ago
        warning_days: 3,
        error_days: 5
    };
    const status = getRepoStatus(repo, now);
    // 12h is well within 3-day warning → healthy.
    if (status === 'healthy') {
        console.log('TEST_RESULT:day-thresholds-unchanged:PASS:day thresholds untouched');
    } else {
        console.log('TEST_RESULT:day-thresholds-unchanged:FAIL:expected healthy, got ' + status);
    }
"

# ============================================================
# Test 8: All Vibe Coder entries in repos.json have hour thresholds
# ============================================================
echo ""
echo "Test 8: repos.json Vibe Coder entries have warning_hours/error_hours..."

REPOS_JSON="$SCRIPT_DIR/../docs/repos.json"
if command -v jq &> /dev/null && [ -f "$REPOS_JSON" ]; then
    MISSING=0
    while IFS=$'\t' read -r name warning_hours error_hours; do
        if [ -z "$warning_hours" ] || [ "$warning_hours" = "null" ]; then
            fail_test "missing warning_hours for: $name"
            MISSING=$((MISSING + 1))
        elif [ -z "$error_hours" ] || [ "$error_hours" = "null" ]; then
            fail_test "missing error_hours for: $name"
            MISSING=$((MISSING + 1))
        else
            pass_test "$name has warning_hours=$warning_hours, error_hours=$error_hours"
        fi
    done < <(jq -r '.repos[] | select(.name | startswith("Vibe Coder")) | [.name, .warning_hours, .error_hours] | @tsv' "$REPOS_JSON")
    if [ "$MISSING" -gt 0 ]; then
        fail_test "$MISSING Vibe Coder entries missing hour thresholds"
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
