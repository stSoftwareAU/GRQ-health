#!/bin/bash
# Test for Issue #77: Dashboard UI — distinguish 'ran and failed' from 'stale'
# Verifies that getRepoStatus returns 'failed' when last_failure_ts is present
# and newer than last_commit_ts, and that a View log URL is built correctly.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/extract-functions.sh
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #77: 'failed' classification and View log link"
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

# ============================================================
# Test 1: getRepoStatus returns 'failed' when last_failure_ts > last_commit_ts
# ============================================================
echo "Test 1: 'failed' when last_failure_ts > last_commit_ts..."
run_and_check "failed-more-recent-than-commit" '
    const now = 1776400000;
    const repo = {
        name: "Quality",
        last_commit_ts: now - 3600,
        last_failure_ts: now - 60,
        last_failure_log: "logs/Quality/20260417-020000.log"
    };
    const status = getRepoStatus(repo, now);
    if (status === "failed") {
        console.log("TEST_RESULT:failed-more-recent-than-commit:PASS:failed status wins when failure is newer");
    } else {
        console.log("TEST_RESULT:failed-more-recent-than-commit:FAIL:expected failed, got " + status);
    }
'

# ============================================================
# Test 2: 'failed' supersedes what would otherwise be 'ok'
# ============================================================
echo ""
echo "Test 2: 'failed' supersedes a fresh successful commit if failure is newer..."
run_and_check "failed-supersedes-ok" '
    const now = 1776400000;
    // last_commit_ts within thresholds (healthy) but later failure
    const repo = {
        name: "FeedA",
        last_commit_ts: now - 3600,
        last_failure_ts: now - 600,
        last_failure_log: "logs/FeedA/20260417-030000.log"
    };
    const status = getRepoStatus(repo, now);
    if (status === "failed") {
        console.log("TEST_RESULT:failed-supersedes-ok:PASS:failed overrides healthy when failure is newer");
    } else {
        console.log("TEST_RESULT:failed-supersedes-ok:FAIL:expected failed, got " + status);
    }
'

# ============================================================
# Test 3: When last_failure_ts is older than last_commit_ts, status is preserved
# ============================================================
echo ""
echo "Test 3: old failure ignored when last_commit_ts is newer..."
run_and_check "old-failure-ignored" '
    const now = 1776400000;
    const repo = {
        name: "FeedB",
        last_commit_ts: now - 600,         // fresh successful run
        last_failure_ts: now - 36000,      // older failure
        last_failure_log: "logs/FeedB/20260416-000000.log"
    };
    const status = getRepoStatus(repo, now);
    if (status === "healthy") {
        console.log("TEST_RESULT:old-failure-ignored:PASS:healthy because success is newer than failure");
    } else {
        console.log("TEST_RESULT:old-failure-ignored:FAIL:expected healthy, got " + status);
    }
'

# ============================================================
# Test 4: Absent last_failure_ts yields the existing status
# ============================================================
echo ""
echo "Test 4: no failure fields -> behaves as before..."
run_and_check "no-failure-fields" '
    const now = 1776400000;
    const repo = { name: "FeedC", last_commit_ts: now - 600 };
    const status = getRepoStatus(repo, now);
    if (status === "healthy") {
        console.log("TEST_RESULT:no-failure-fields:PASS:repo with only success stays healthy");
    } else {
        console.log("TEST_RESULT:no-failure-fields:FAIL:expected healthy, got " + status);
    }
'

# ============================================================
# Test 5: failed beats error (stale) when both are true — we prefer the actionable failure
# ============================================================
echo ""
echo "Test 5: 'failed' wins over stale 'error' when both apply..."
run_and_check "failed-beats-stale" '
    // last_commit_ts is very old (stale -> would be error)
    // but the MOST RECENT thing we know about is a failure
    // so we prefer the failure state.
    const now = 1776400000;
    const tenDays = 10 * 86400;
    const repo = {
        name: "FeedD",
        last_commit_ts: now - tenDays,
        last_failure_ts: now - 60,
        last_failure_log: "logs/FeedD/20260417-040000.log"
    };
    const status = getRepoStatus(repo, now);
    if (status === "failed") {
        console.log("TEST_RESULT:failed-beats-stale:PASS:failed chosen over stale error when failure is newer");
    } else {
        console.log("TEST_RESULT:failed-beats-stale:FAIL:expected failed, got " + status);
    }
'

# ============================================================
# Test 6: Equal timestamps — last_failure_ts == last_commit_ts — treated as failed
# ============================================================
echo ""
echo "Test 6: equal timestamps resolved in favour of failed..."
run_and_check "failed-equal-ts" '
    const now = 1776400000;
    const repo = {
        name: "FeedE",
        last_commit_ts: now - 300,
        last_failure_ts: now - 300,
        last_failure_log: "logs/FeedE/20260417-050000.log"
    };
    const status = getRepoStatus(repo, now);
    if (status === "failed") {
        console.log("TEST_RESULT:failed-equal-ts:PASS:equal timestamps classify as failed");
    } else {
        console.log("TEST_RESULT:failed-equal-ts:FAIL:expected failed, got " + status);
    }
'

# ============================================================
# Test 7: getRepoStats includes a failed counter
# ============================================================
echo ""
echo "Test 7: getRepoStats counts failed entries separately..."
run_and_check "stats-failed-counter" '
    const now = Math.floor(Date.now() / 1000);
    // getRepoStats accepts an optional repos array for testing.
    const repos = [
        { name: "A", last_commit_ts: now - 60 },                                    // healthy
        { name: "B", last_commit_ts: now - 60,
          last_failure_ts: now - 30,
          last_failure_log: "logs/B/x.log" },                                       // failed
        { name: "C", last_commit_ts: now - 60,
          last_failure_ts: now - 30,
          last_failure_log: "logs/C/x.log" }                                        // failed
    ];
    const stats = getRepoStats(repos);
    if (stats.failed === 2 && stats.healthy === 1 && stats.total === 3) {
        console.log("TEST_RESULT:stats-failed-counter:PASS:2 failed + 1 healthy as expected");
    } else {
        console.log("TEST_RESULT:stats-failed-counter:FAIL:got " + JSON.stringify(stats));
    }
'

# ============================================================
# Test 8: getRepoFailureLogUrl builds a correctly encoded URL (simple case)
# ============================================================
echo ""
echo "Test 8: getRepoFailureLogUrl builds expected URL for simple path..."
run_and_check "log-url-simple" '
    const url = getRepoFailureLogUrl({ last_failure_log: "logs/Quality/20260417-025717.log" });
    const expected = "./log-viewer.html?file=./logs/Quality/20260417-025717.log";
    if (url === expected) {
        console.log("TEST_RESULT:log-url-simple:PASS:built correct url");
    } else {
        console.log("TEST_RESULT:log-url-simple:FAIL:expected " + expected + ", got " + url);
    }
'

# ============================================================
# Test 9: getRepoFailureLogUrl handles task names with spaces/colons (e.g. Vibe Coder:GRQ-23)
# ============================================================
echo ""
echo "Test 9: getRepoFailureLogUrl encodes task slugs with unsafe chars..."
run_and_check "log-url-encoded" '
    // The path passed in will already be a relative path from the helper.
    // But a task name like "Vibe Coder:GRQ-23" may still contain unsafe
    // characters in some callers, so the builder must encode them safely
    // (no double-encoding of the "/" separators).
    const repo = { last_failure_log: "logs/Vibe Coder-GRQ-23/20260417-060000.log" };
    const url = getRepoFailureLogUrl(repo);
    // Must contain encoded space
    if (!url.includes("%20") && !url.includes("+")) {
        console.log("TEST_RESULT:log-url-encoded:FAIL:space was not encoded: " + url);
    } else if (url.indexOf("%252F") !== -1) {
        console.log("TEST_RESULT:log-url-encoded:FAIL:double-encoded / in: " + url);
    } else if (!url.startsWith("./log-viewer.html?file=")) {
        console.log("TEST_RESULT:log-url-encoded:FAIL:missing log-viewer prefix: " + url);
    } else if (!url.endsWith(".log")) {
        console.log("TEST_RESULT:log-url-encoded:FAIL:does not end with .log: " + url);
    } else {
        console.log("TEST_RESULT:log-url-encoded:PASS:" + url);
    }
'

# ============================================================
# Test 10: getRepoFailureLogUrl returns empty string when no log present
# ============================================================
echo ""
echo "Test 10: getRepoFailureLogUrl returns empty when repo has no failure log..."
run_and_check "log-url-absent" '
    const url1 = getRepoFailureLogUrl({});
    const url2 = getRepoFailureLogUrl({ last_failure_log: "" });
    const url3 = getRepoFailureLogUrl(null);
    if (url1 === "" && url2 === "" && url3 === "") {
        console.log("TEST_RESULT:log-url-absent:PASS:empty for missing/empty/null");
    } else {
        console.log("TEST_RESULT:log-url-absent:FAIL:" + JSON.stringify([url1,url2,url3]));
    }
'

echo ""
echo "============================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
