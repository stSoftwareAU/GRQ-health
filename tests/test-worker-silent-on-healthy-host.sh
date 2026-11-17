#!/bin/bash
# Test for Issue #121: Distinguish 'host offline' from 'Vibe Coder worker
# silent' on the dashboard.
#
# Background: a host's heartbeat (run.sh's "Update health status for $HOSTNAME")
# and the Vibe Coder worker's heartbeat (Vibe Coder:<HOST> repo entry) come
# from two independent processes on the same machine. Today, when the host
# itself is fresh but the worker stops reporting, the host card still shows
# 'healthy' and the warning only appears in the unrelated repo list — diagnosis
# is delayed until the 8h error threshold trips.
#
# This test enforces the new helpers used to detect that mismatch:
#   1. findVibeCoderRepo locates a matching "Vibe Coder:<host>" repo.
#   2. isWorkerSilentState recognises the warning/error/failed worker states.
#   3. getWorkerSilentInfo returns details only when the worker is silent.
#   4. The host card surfaces a "Worker silent" badge in the warning bucket
#      even when the host's own heartbeat is fresh (host gets elevated to
#      'warning').

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #121: Worker-silent-on-healthy-host detection"
echo "==========================================================="
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
# Test 1: findVibeCoderRepo locates the matching Vibe Coder entry
# ============================================================
echo "Test 1: findVibeCoderRepo finds 'Vibe Coder:<host>' by hostname..."

run_and_check "find-vibe-repo" "
    const repos = [
        { name: 'Sentiment', last_commit_ts: 1 },
        { name: 'Vibe Coder:GRQ-23', last_commit_ts: 2 },
        { name: 'Vibe Coder:Mac-Ultra-M2', last_commit_ts: 3 }
    ];
    const found = findVibeCoderRepo(repos, 'GRQ-23');
    if (found && found.name === 'Vibe Coder:GRQ-23') {
        console.log('TEST_RESULT:find-vibe-repo:PASS:matched ' + found.name);
    } else {
        console.log('TEST_RESULT:find-vibe-repo:FAIL:got ' + JSON.stringify(found));
    }
"

# ============================================================
# Test 2: findVibeCoderRepo returns null when there is no match
# ============================================================
echo ""
echo "Test 2: findVibeCoderRepo returns null for hosts with no worker repo..."

run_and_check "find-vibe-repo-missing" "
    const repos = [
        { name: 'Vibe Coder:GRQ-23', last_commit_ts: 1 }
    ];
    const found = findVibeCoderRepo(repos, 'GRQ-99');
    if (found === null) {
        console.log('TEST_RESULT:find-vibe-repo-missing:PASS:no match returns null');
    } else {
        console.log('TEST_RESULT:find-vibe-repo-missing:FAIL:got ' + JSON.stringify(found));
    }
"

# ============================================================
# Test 3: isWorkerSilentState classifies warning/error/failed as silent
# ============================================================
echo ""
echo "Test 3: isWorkerSilentState recognises warning/error/failed..."

run_and_check "worker-silent-states" "
    const cases = [
        ['warning', true],
        ['error', true],
        ['failed', true],
        ['healthy', false],
        ['', false],
        [null, false]
    ];
    let bad = '';
    for (const [state, expected] of cases) {
        const got = isWorkerSilentState(state);
        if (got !== expected) {
            bad += state + '=' + got + '(want ' + expected + ');';
        }
    }
    if (!bad) {
        console.log('TEST_RESULT:worker-silent-states:PASS:all states match');
    } else {
        console.log('TEST_RESULT:worker-silent-states:FAIL:' + bad);
    }
"

# ============================================================
# Test 4: getWorkerSilentInfo returns details when worker is warning
# ============================================================
echo ""
echo "Test 4: getWorkerSilentInfo returns info when worker is warning..."

run_and_check "worker-silent-info-warning" "
    const now = ${NOW};
    const repos = [
        {
            name: 'Vibe Coder:GRQ-23',
            last_commit_ts: now - (5 * 60 * 60), // 5h ago -> warning under 4/8
            warning_hours: 4,
            error_hours: 8
        }
    ];
    const info = getWorkerSilentInfo('GRQ-23', repos, now);
    if (info && info.repoStatus === 'warning' && info.repoName === 'Vibe Coder:GRQ-23') {
        console.log('TEST_RESULT:worker-silent-info-warning:PASS:warning detected');
    } else {
        console.log('TEST_RESULT:worker-silent-info-warning:FAIL:got ' + JSON.stringify(info));
    }
"

# ============================================================
# Test 5: getWorkerSilentInfo returns null when worker is healthy
# ============================================================
echo ""
echo "Test 5: getWorkerSilentInfo returns null when worker is healthy..."

run_and_check "worker-silent-info-healthy" "
    const now = ${NOW};
    const repos = [
        {
            name: 'Vibe Coder:GRQ-23',
            last_commit_ts: now - (30 * 60), // 30m ago -> healthy
            warning_hours: 4,
            error_hours: 8
        }
    ];
    const info = getWorkerSilentInfo('GRQ-23', repos, now);
    if (info === null) {
        console.log('TEST_RESULT:worker-silent-info-healthy:PASS:no info when healthy');
    } else {
        console.log('TEST_RESULT:worker-silent-info-healthy:FAIL:got ' + JSON.stringify(info));
    }
"

# ============================================================
# Test 6: getWorkerSilentInfo returns null when host has no worker repo
# ============================================================
echo ""
echo "Test 6: getWorkerSilentInfo returns null when no worker repo exists..."

run_and_check "worker-silent-info-no-repo" "
    const now = ${NOW};
    const repos = [];
    const info = getWorkerSilentInfo('GRQ-23', repos, now);
    if (info === null) {
        console.log('TEST_RESULT:worker-silent-info-no-repo:PASS:no info without repo');
    } else {
        console.log('TEST_RESULT:worker-silent-info-no-repo:FAIL:got ' + JSON.stringify(info));
    }
"

# ============================================================
# Test 7: buildWorkerSilentWarning produces a human-readable reason
# ============================================================
echo ""
echo "Test 7: buildWorkerSilentWarning produces human-readable reason..."

run_and_check "worker-silent-warning-text" "
    const now = ${NOW};
    const repos = [
        {
            name: 'Vibe Coder:GRQ-23',
            last_commit_ts: now - (5 * 60 * 60),
            warning_hours: 4,
            error_hours: 8
        }
    ];
    const text = buildWorkerSilentWarning('GRQ-23', repos, now);
    if (text && text.includes('Worker silent') && text.includes('Vibe Coder:GRQ-23')) {
        console.log('TEST_RESULT:worker-silent-warning-text:PASS:' + text);
    } else {
        console.log('TEST_RESULT:worker-silent-warning-text:FAIL:got ' + JSON.stringify(text));
    }
"

# ============================================================
# Test 8: buildWorkerSilentWarning returns empty string when fine
# ============================================================
echo ""
echo "Test 8: buildWorkerSilentWarning returns empty when worker healthy..."

run_and_check "worker-silent-warning-empty" "
    const now = ${NOW};
    const repos = [
        {
            name: 'Vibe Coder:GRQ-23',
            last_commit_ts: now - (60 * 60), // 1h ago -> healthy
            warning_hours: 4,
            error_hours: 8
        }
    ];
    const text = buildWorkerSilentWarning('GRQ-23', repos, now);
    if (text === '') {
        console.log('TEST_RESULT:worker-silent-warning-empty:PASS:empty when healthy');
    } else {
        console.log('TEST_RESULT:worker-silent-warning-empty:FAIL:got ' + JSON.stringify(text));
    }
"

# ============================================================
# Test 9: Worker error state also triggers worker-silent info
# ============================================================
echo ""
echo "Test 9: Worker error (>=8h stale) also surfaces as worker silent..."

run_and_check "worker-silent-info-error" "
    const now = ${NOW};
    const repos = [
        {
            name: 'Vibe Coder:GRQ-23',
            last_commit_ts: now - (11 * 60 * 60), // 11h ago -> error
            warning_hours: 4,
            error_hours: 8
        }
    ];
    const info = getWorkerSilentInfo('GRQ-23', repos, now);
    if (info && info.repoStatus === 'error') {
        console.log('TEST_RESULT:worker-silent-info-error:PASS:error detected');
    } else {
        console.log('TEST_RESULT:worker-silent-info-error:FAIL:got ' + JSON.stringify(info));
    }
"

echo ""
echo "==========================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
