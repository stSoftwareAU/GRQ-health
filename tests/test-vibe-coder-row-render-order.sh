#!/bin/bash
# Test for Issue #212: the repo rows must render *after* the host records land.
#
# The diagnosis that turns a dead-looking "Vibe Coder:<host>" row into
# "Hooks failing" or "Idle" reads the worker state out of the host records
# (`allHosts`). loadData fetches index.json and repos.json in the same pass, so
# if the repo rows are rendered before `allHosts` is populated the diagnosis has
# no state to read and every row falls back to "Error" — exactly the symptom the
# issue reports, with the fix in place but invisible.
#
# This test drives the real loadData / loadDataIncremental against stubbed
# fetch + DOM and asserts what the renderer could actually see.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_JS="$SCRIPT_DIR/../docs/dashboard.js"
# shellcheck source=tests/find-deno.sh
source "$SCRIPT_DIR/find-deno.sh"

echo "Testing Issue #212: host records are in place before the repo rows render"
echo "========================================================================"
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

run_case() {
    local test_name="$1" js_code="$2"
    local output result detail
    output=$(printf '%s' "$js_code" | "$DENO" run --allow-read="$DASHBOARD_JS" - "$DASHBOARD_JS" 2>&1) || true
    result=$(echo "$output" | grep "^TEST_RESULT:${test_name}:" | head -1)
    detail=$(echo "$result" | cut -d: -f4-)
    if [[ "$result" == *":PASS:"* ]]; then
        pass_test "$test_name: $detail"
    else
        [ -z "$detail" ] && detail="no output (full: $output)"
        fail_test "$test_name: $detail"
    fi
}

# The harness: load dashboard.js whole (the pure-function extractor cannot see
# loadData), stub the browser surface it touches at import time, then stub the
# renderer so each test can observe what it was given.
HARNESS=$(cat <<'HARNESS_EOF'
const source = await Deno.readTextFile(Deno.args[0]);

const element = {
    innerHTML: '', textContent: '', style: {}, classList: { add() {}, remove() {} },
    addEventListener() {}, querySelector: () => null, querySelectorAll: () => [],
    appendChild() {}, replaceWith() {}
};
const documentStub = {
    title: '', addEventListener() {}, getElementById: () => element,
    querySelector: () => element, querySelectorAll: () => [],
    createElement: () => element, body: element
};

function loadDashboard(fetchStub) {
    const factory = new Function(
        'document', 'window', 'fetch', 'setInterval', 'setTimeout', 'console', 'navigator',
        `${source}
        return {
            loadData, loadDataIncremental, getRepoStatusWithDiagnosis,
            hosts: () => allHosts,
            stub(name, fn) { eval(name + ' = fn'); }
        };`
    );
    return factory(
        documentStub,
        { addEventListener() {}, location: { href: '' } },
        fetchStub,
        () => 0,
        () => 0,
        { log() {}, warn() {}, error() {} },
        { serviceWorker: undefined, onLine: true }
    );
}

const jsonResponse = (body) => Promise.resolve({ ok: true, json: () => Promise.resolve(body) });

function buildFixture(nowMs) {
    const now = Math.floor(nowMs / 1000);
    const staleRow = {
        name: 'Vibe Coder:GRQ-25',
        last_commit_ts: now - (20 * 60 * 60),
        warning_hours: 4,
        error_hours: 8
    };
    const hostRecords = {
        'GRQ-25': {
            heart_beat_ts: now - 60,
            vibe_coder: {
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
            }
        }
    };
    return { staleRow, hostRecords };
}
HARNESS_EOF
)

# ============================================================
# Test 1: the first full load renders rows with the host state
# ============================================================
echo "Test 1: loadData renders the repo rows after the host records land..."
run_case "render-order-full-load" "${HARNESS}
const { staleRow, hostRecords } = buildFixture(Date.now());

const app = loadDashboard((url) => {
    if (String(url).startsWith('./index.json')) return jsonResponse(hostRecords);
    if (String(url).startsWith('./repos.json')) return jsonResponse({ repos: [staleRow] });
    return jsonResponse({});
});

let seen = null;
app.stub('renderRepoHealth', () => { seen = app.getRepoStatusWithDiagnosis(staleRow, app.hosts()); });
app.stub('fetchFeedCompletion', () => Promise.resolve());
app.stub('refreshHealthStatuses', () => {});
app.stub('updateStats', () => {});
app.stub('filterHosts', () => {});
app.stub('initializeTooltips', () => {});

await app.loadData();

if (!seen) {
    console.log('TEST_RESULT:render-order-full-load:FAIL:renderRepoHealth was never called');
} else if (seen.status === 'warning' && seen.diagnosis && seen.diagnosis.label === 'Hooks failing') {
    console.log('TEST_RESULT:render-order-full-load:PASS:rendered as ' + seen.diagnosis.label);
} else {
    console.log('TEST_RESULT:render-order-full-load:FAIL:rendered as ' + seen.status + ' — host records were not in place yet');
}
"

# ============================================================
# Test 2: an incremental refresh re-renders the rows
# ============================================================
echo ""
echo "Test 2: loadDataIncremental re-renders the rows when host state changes..."
run_case "render-order-incremental" "${HARNESS}
const { staleRow, hostRecords } = buildFixture(Date.now());

// First pass: no worker state published yet, so the row is genuinely dead.
const bare = { 'GRQ-25': { heart_beat_ts: hostRecords['GRQ-25'].heart_beat_ts } };
let hostPayload = bare;

const app = loadDashboard((url) => {
    if (String(url).startsWith('./index.json')) return jsonResponse(hostPayload);
    if (String(url).startsWith('./repos.json')) return jsonResponse({ repos: [staleRow] });
    return jsonResponse({});
});

let seen = null;
app.stub('renderRepoHealth', () => { seen = app.getRepoStatusWithDiagnosis(staleRow, app.hosts()); });
app.stub('fetchFeedCompletion', () => Promise.resolve());
app.stub('refreshHealthStatuses', () => {});
app.stub('updateStats', () => {});
app.stub('filterHosts', () => {});
app.stub('initializeTooltips', () => {});
app.stub('updateHostCard', () => {});
app.stub('showUpdateIndicator', () => {});

await app.loadData();
const first = seen ? seen.status : 'never-rendered';

// The worker state now arrives; the rows must be re-rendered with it.
hostPayload = hostRecords;
seen = null;
await app.loadDataIncremental();

if (first !== 'error') {
    console.log('TEST_RESULT:render-order-incremental:FAIL:first pass should be error, was ' + first);
} else if (seen && seen.status === 'warning' && seen.diagnosis && seen.diagnosis.label === 'Hooks failing') {
    console.log('TEST_RESULT:render-order-incremental:PASS:error then ' + seen.diagnosis.label);
} else {
    console.log('TEST_RESULT:render-order-incremental:FAIL:second pass rendered ' + (seen ? seen.status : 'nothing') + ' — new worker state not applied to the rows');
}
"

echo ""
echo "====================================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

[ "$FAIL_COUNT" -eq 0 ]
