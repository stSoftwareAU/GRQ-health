#!/bin/bash
# Test for Issue #212: a stale "Vibe Coder:<host>" row is diagnosed, not just
# declared dead.
#
# test-vibe-coder-dead-after-8h.sh asserts the 8h threshold that turns the row
# red. This companion test asserts what the dashboard does with the worker
# state run.sh now publishes alongside it:
#
#   * host fresh, row stale, hook failures present  => 'hooks failing'
#   * host fresh, row stale, nothing claimed lately => 'idle'
#   * host fresh, row stale, no explanation         => stays 'error'
#
# Only a row that getRepoStatus already calls 'error' is reinterpreted — a
# genuinely dead worker (no fresh liveness) must stay dead.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #212: hooks-failing / idle diagnosis for Vibe Coder rows"
echo "====================================================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

run_and_check() {
    local test_name="$1"
    local js_code="$2"
    local output
    output=$(run_js_test "$js_code" 2>&1) || true
    local result
    result=$(echo "$output" | grep "^TEST_RESULT:${test_name}:" | head -1)
    if [[ "$result" == *":PASS:"* ]]; then
        pass_test "$test_name: $(echo "$result" | cut -d: -f4-)"
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

# Shared fixture builder: a row that went stale 20h ago on a host whose worker
# reported itself alive 10 minutes ago.
FIXTURE="
    const now = ${NOW};
    const staleRow = {
        name: 'Vibe Coder:GRQ-25',
        last_commit_ts: now - (20 * 60 * 60),
        warning_hours: 4,
        error_hours: 8
    };
    const hooksFailingState = {
        worker_live_ts: now - (10 * 60),
        last_success_ts: now - (30 * 60),
        last_claim_ts: now - (35 * 60),
        run_pid_alive: true,
        hook_failures: {
            success: 12,
            failure: 2,
            since_ts: now - (21 * 60 * 60),
            last_stderr: 'could not fetch https://github.com/stSoftwareAU/GRQ-health.git'
        },
        volume_reset_ts: now - (22 * 60 * 60)
    };
"

# ============================================================
# Test 1: 'Vibe Coder:<host>' row names resolve to the host
# ============================================================
echo "Test 1: getVibeCoderHostname extracts the host from the row name..."

run_and_check "vibe-hostname" "
    const cases = [
        ['Vibe Coder:GRQ-25', 'GRQ-25'],
        ['Vibe Coder:Mac-Ultra-M2', 'Mac-Ultra-M2'],
        ['Sentiment', ''],
        ['', ''],
        [null, '']
    ];
    let bad = '';
    for (const [name, expected] of cases) {
        const got = getVibeCoderHostname(name);
        if (got !== expected) bad += JSON.stringify(name) + '=>' + JSON.stringify(got) + ';';
    }
    if (!bad) {
        console.log('TEST_RESULT:vibe-hostname:PASS:all row names resolved');
    } else {
        console.log('TEST_RESULT:vibe-hostname:FAIL:' + bad);
    }
"

# ============================================================
# Test 2: the worker state is read off the host record
# ============================================================
echo ""
echo "Test 2: findVibeCoderState reads vibe_coder from the host entry..."

run_and_check "vibe-find-state" "
    const hosts = [
        ['GRQ-23', { heart_beat_ts: 1 }],
        ['GRQ-25', { heart_beat_ts: 2, vibe_coder: { worker_live_ts: 99 } }]
    ];
    const found = findVibeCoderState(hosts, 'GRQ-25');
    const missing = findVibeCoderState(hosts, 'GRQ-23');
    const absent = findVibeCoderState(hosts, 'GRQ-99');
    if (found && found.worker_live_ts === 99 && missing === null && absent === null) {
        console.log('TEST_RESULT:vibe-find-state:PASS:state found, absent hosts null');
    } else {
        console.log('TEST_RESULT:vibe-find-state:FAIL:' + JSON.stringify([found, missing, absent]));
    }
"

# ============================================================
# Test 3: the outage this issue came from — hooks failing
# ============================================================
echo ""
echo "Test 3: live worker + failing hooks => 'hooks failing', not dead..."

run_and_check "vibe-hooks-failing" "
    ${FIXTURE}
    const diag = diagnoseVibeCoderRow(staleRow, hooksFailingState, now);
    if (diag && diag.state === 'hooks-failing' && diag.status === 'warning'
        && diag.label === 'Hooks failing'
        && diag.detail.includes('GRQ-health.git')) {
        console.log('TEST_RESULT:vibe-hooks-failing:PASS:' + diag.label + ' — ' + diag.detail);
    } else {
        console.log('TEST_RESULT:vibe-hooks-failing:FAIL:' + JSON.stringify(diag));
    }
"

# ============================================================
# Test 4: the row's rendered status follows the diagnosis
# ============================================================
echo ""
echo "Test 4: getRepoStatusWithDiagnosis downgrades error to warning..."

run_and_check "vibe-status-warning" "
    ${FIXTURE}
    const hosts = [['GRQ-25', { vibe_coder: hooksFailingState }]];
    const plain = getRepoStatus(staleRow, now);
    const resolved = getRepoStatusWithDiagnosis(staleRow, hosts, now);
    if (plain === 'error' && resolved.status === 'warning' && resolved.diagnosis.state === 'hooks-failing') {
        console.log('TEST_RESULT:vibe-status-warning:PASS:error row renders as warning');
    } else {
        console.log('TEST_RESULT:vibe-status-warning:FAIL:' + JSON.stringify([plain, resolved]));
    }
"

# ============================================================
# Test 5: nothing claimable for the whole error window => idle
# ============================================================
echo ""
echo "Test 5: live worker with nothing claimed in the error window => idle..."

run_and_check "vibe-idle" "
    ${FIXTURE}
    const idleState = Object.assign({}, hooksFailingState, {
        last_success_ts: now - (25 * 60 * 60),
        last_claim_ts: now - (25 * 60 * 60),
        hook_failures: { success: 0, failure: 0, since_ts: 0, last_stderr: '' }
    });
    const diag = diagnoseVibeCoderRow(staleRow, idleState, now);
    if (diag && diag.state === 'idle' && diag.status === 'healthy' && diag.label === 'Idle') {
        console.log('TEST_RESULT:vibe-idle:PASS:' + diag.detail);
    } else {
        console.log('TEST_RESULT:vibe-idle:FAIL:' + JSON.stringify(diag));
    }
"

# ============================================================
# Test 6: a dead worker stays dead
# ============================================================
echo ""
echo "Test 6: no fresh liveness => the row stays 'error'..."

run_and_check "vibe-dead-stays-dead" "
    ${FIXTURE}
    const deadState = Object.assign({}, hooksFailingState, {
        worker_live_ts: now - (30 * 60 * 60)
    });
    const diag = diagnoseVibeCoderRow(staleRow, deadState, now);
    const hosts = [['GRQ-25', { vibe_coder: deadState }]];
    const resolved = getRepoStatusWithDiagnosis(staleRow, hosts, now);
    if (diag === null && resolved.status === 'error' && resolved.diagnosis === null) {
        console.log('TEST_RESULT:vibe-dead-stays-dead:PASS:stale liveness keeps the row dead');
    } else {
        console.log('TEST_RESULT:vibe-dead-stays-dead:FAIL:' + JSON.stringify([diag, resolved]));
    }
"

# ============================================================
# Test 7: a live worker whose every issue fails stays 'error'
# ============================================================
echo ""
echo "Test 7: live worker, claiming, no hook failures => stays 'error'..."

run_and_check "vibe-failing-issues-stays-error" "
    ${FIXTURE}
    const failingState = Object.assign({}, hooksFailingState, {
        last_success_ts: now - (30 * 60 * 60),
        last_claim_ts: now - (10 * 60),
        hook_failures: { success: 0, failure: 0, since_ts: 0, last_stderr: '' }
    });
    const diag = diagnoseVibeCoderRow(staleRow, failingState, now);
    if (diag === null) {
        console.log('TEST_RESULT:vibe-failing-issues-stays-error:PASS:unexplained staleness stays error');
    } else {
        console.log('TEST_RESULT:vibe-failing-issues-stays-error:FAIL:' + JSON.stringify(diag));
    }
"

# ============================================================
# Test 8: a healthy row is never reinterpreted
# ============================================================
echo ""
echo "Test 8: a healthy row is left alone..."

run_and_check "vibe-healthy-untouched" "
    ${FIXTURE}
    const freshRow = Object.assign({}, staleRow, { last_commit_ts: now - (30 * 60) });
    const diag = diagnoseVibeCoderRow(freshRow, hooksFailingState, now);
    if (diag === null) {
        console.log('TEST_RESULT:vibe-healthy-untouched:PASS:healthy rows are not diagnosed');
    } else {
        console.log('TEST_RESULT:vibe-healthy-untouched:FAIL:' + JSON.stringify(diag));
    }
"

# ============================================================
# Test 9: a success older than the row is not 'hooks failing'
# ============================================================
echo ""
echo "Test 9: hook failures with no newer success do not claim 'hooks failing'..."

run_and_check "vibe-stale-success" "
    ${FIXTURE}
    const oldSuccessState = Object.assign({}, hooksFailingState, {
        last_success_ts: staleRow.last_commit_ts - 60,
        last_claim_ts: now - (10 * 60)
    });
    const diag = diagnoseVibeCoderRow(staleRow, oldSuccessState, now);
    if (diag === null) {
        console.log('TEST_RESULT:vibe-stale-success:PASS:no success after the row means no hook diagnosis');
    } else {
        console.log('TEST_RESULT:vibe-stale-success:FAIL:' + JSON.stringify(diag));
    }
"

# ============================================================
# Test 10: hosts with no worker state are unaffected
# ============================================================
echo ""
echo "Test 10: a host record without vibe_coder leaves the row as-is..."

run_and_check "vibe-no-state" "
    ${FIXTURE}
    const hosts = [['GRQ-25', { heart_beat_ts: now }]];
    const resolved = getRepoStatusWithDiagnosis(staleRow, hosts, now);
    const other = getRepoStatusWithDiagnosis({ name: 'Sentiment', last_commit_ts: now - (20 * 60 * 60), warning_hours: 4, error_hours: 8 }, hosts, now);
    if (resolved.status === 'error' && resolved.diagnosis === null && other.status === 'error') {
        console.log('TEST_RESULT:vibe-no-state:PASS:rows without worker state keep their status');
    } else {
        console.log('TEST_RESULT:vibe-no-state:FAIL:' + JSON.stringify([resolved, other]));
    }
"

# ============================================================
# Test 11: the counters agree with the rows
# ============================================================
echo ""
echo "Test 11: getRepoStats counts a hooks-failing row as a warning..."

run_and_check "vibe-stats" "
    ${FIXTURE}
    const hosts = [['GRQ-25', { vibe_coder: hooksFailingState }]];
    const before = getRepoStats([staleRow], [], now);
    const after = getRepoStats([staleRow], hosts, now);
    if (before.error === 1 && before.warning === 0 && after.error === 0 && after.warning === 1) {
        console.log('TEST_RESULT:vibe-stats:PASS:error 1->0, warning 0->1');
    } else {
        console.log('TEST_RESULT:vibe-stats:FAIL:' + JSON.stringify([before, after]));
    }
"

# ============================================================
# Test 12: the stderr excerpt is bounded
# ============================================================
echo ""
echo "Test 12: a very long hook stderr is truncated for the board..."

run_and_check "vibe-stderr-bounded" "
    ${FIXTURE}
    const longState = Object.assign({}, hooksFailingState, {
        hook_failures: Object.assign({}, hooksFailingState.hook_failures, {
            last_stderr: 'x'.repeat(4000)
        })
    });
    const diag = diagnoseVibeCoderRow(staleRow, longState, now);
    if (diag && diag.detail.length <= 320) {
        console.log('TEST_RESULT:vibe-stderr-bounded:PASS:detail is ' + diag.detail.length + ' chars');
    } else {
        console.log('TEST_RESULT:vibe-stderr-bounded:FAIL:' + (diag ? diag.detail.length : 'null'));
    }
"

echo ""
echo "====================================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
