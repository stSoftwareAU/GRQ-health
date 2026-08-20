#!/bin/bash
# Test for GRQ#4174: per-day feed-completion panel.
#
# The panel makes a failed or never-run fetch loud to a human (fail loud,
# GRQ#3234) — the scorer gate's own reaction is deliberately quiet. The
# regressions that matter: an absent feed reading as healthy (silently opens
# the gate's story on stale data), `no-change` not reading as healthy or being
# indistinguishable from `complete`, a `failed` row losing its exit code /
# log link, a non-trading day rendering as an all-red panel, and the day-file
# validation accepting a stale clone artefact whose ny_date disagrees.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

DASHBOARD="$SCRIPT_DIR/../docs/dashboard.js"
INDEX_HTML="$SCRIPT_DIR/../docs/index.html"

echo "Testing GRQ#4174: feed-completion panel"
echo "======================================="
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

check_output() {
    # Count TEST_RESULT lines; any FAIL fails the block.
    local output="$1"
    echo "$output" | grep '^TEST_RESULT:' | while IFS=: read -r _ name status detail; do
        echo "  ${status}: ${name} — ${detail}"
    done
    if echo "$output" | grep -q '^TEST_RESULT:.*:FAIL:'; then
        return 1
    fi
    return 0
}

echo "Test 1: pure helpers (date key, trading day, rows, rollup)..."
OUTPUT=$(run_js_test '
function t(name, ok, detail) {
    console.log(`TEST_RESULT:${name}:${ok ? "PASS" : "FAIL"}:${detail}`);
}

// NY date key: 2026-08-19 is EDT (UTC-4); 03:59Z on the 20th is still the 19th in NY.
t("ny-key-midday", nyDateKeyFor(new Date("2026-08-19T12:00:00Z")) === "20260819", "midday UTC maps to same NY date");
t("ny-key-before-midnight", nyDateKeyFor(new Date("2026-08-20T03:59:00Z")) === "20260819", "03:59Z is 23:59 NY previous day");
t("ny-key-after-midnight", nyDateKeyFor(new Date("2026-08-20T04:01:00Z")) === "20260820", "04:01Z is 00:01 NY new day");

// Trading day = weekday (holidays intentionally ignored, as NyseSchedule documents).
t("trading-wed", isNyTradingDayKey("20260819") === true, "Wednesday is a trading day");
t("trading-sat", isNyTradingDayKey("20260822") === false, "Saturday is not");
t("trading-sun", isNyTradingDayKey("20260823") === false, "Sunday is not");
t("trading-garbage", isNyTradingDayKey("not-a-key") === false, "garbage is not");

// Day-file validation: ny_date must match the requested key (stale clone artefact).
const goodDoc = { ny_date: "20260819", feeds: { shareprices: { status: "complete", ts: 1, host: "GRQ-11" } } };
t("doc-valid", parseFeedDayDoc(goodDoc, "20260819") !== null, "matching ny_date accepted");
t("doc-mismatch", parseFeedDayDoc({ ny_date: "20260818", feeds: {} }, "20260819") === null, "mismatched ny_date rejected");
t("doc-malformed", parseFeedDayDoc({ nothing: true }, "20260819") === null, "shapeless doc rejected");

// Row classification: complete and no-change are BOTH healthy but distinct.
const day = { ny_date: "20260819", feeds: {
    "shareprices": { status: "complete", ts: 100, host: "GRQ-11", detail: "fetch.txt=20260819" },
    "commodities": { status: "no-change", ts: 101, host: "GRQ-11" },
    "insiders": { status: "failed", ts: 102, host: "GRQ-11", exit_code: 1,
                  log: "logs/Insiders/20260819-102101.log", message: "Push failed" },
    "sentiment-tickers": { status: "complete", ts: 103, host: "GRQ-3" },
}};
const rows = buildFeedRows(day, 5.5);
const byName = Object.fromEntries(rows.map(r => [r.name, r]));
t("rows-count", rows.length === 5, `one row per registry feed (${rows.length})`);
t("row-complete", byName["shareprices"].state === "complete" && byName["shareprices"].text === "committed new data", "complete reads committed new data");
t("row-no-change", byName["commodities"].state === "no-change" && byName["commodities"].text === "no new data", "no-change reads no new data");
t("row-texts-differ", byName["shareprices"].text !== byName["commodities"].text, "complete and no-change are distinguishable");
t("row-failed", byName["insiders"].state === "failed" && byName["insiders"].exitCode === 1 && byName["insiders"].log.length > 0, "failed carries exit code and log");
t("row-missing", byName["sentiment-topics"].state === "missing" && byName["sentiment-topics"].text.indexOf("not run") === 0, "absent feed is not run, never healthy");
t("row-missing-aged", byName["sentiment-topics"].text.indexOf("5h into the NY day") > 0, "missing row is aged by the open window");

// Rollup precedence: failed > pending > complete; weekend short-circuits.
t("rollup-failed", getFeedRollup(rows, true).state === "failed", "any failed feed rolls up failed");
const allGood = buildFeedRows({ ny_date: "20260819", feeds: {
    "shareprices": { status: "complete", ts: 1 }, "commodities": { status: "no-change", ts: 1 },
    "insiders": { status: "complete", ts: 1 }, "sentiment-tickers": { status: "no-change", ts: 1 },
    "sentiment-topics": { status: "complete", ts: 1 } } }, 2);
t("rollup-complete", getFeedRollup(allGood, true).state === "complete", "all complete/no-change rolls up complete");
const absentFile = buildFeedRows(null, 2);
t("rollup-pending", getFeedRollup(absentFile, true).state === "pending", "absent day-file rolls up pending, not complete");
t("rollup-weekend", getFeedRollup(absentFile, false).state === "no-trading-day", "weekend rolls up no-trading-day");

// Log-viewer URL shared with the repo failure links.
t("log-url", buildLogViewerUrl("logs/Insiders/a b.log") === "./log-viewer.html?file=./logs/Insiders/a%20b.log", "segments are encoded");
t("log-url-empty", buildLogViewerUrl("") === "", "empty path yields no link");
t("repo-log-delegates", getRepoFailureLogUrl({ last_failure_log: "logs/x.log" }) === buildLogViewerUrl("logs/x.log"), "repo links reuse the shared builder");
')
if check_output "$OUTPUT"; then
    pass_test "pure feed helpers behave per the GRQ#4174 contract"
else
    fail_test "pure feed helper regressions (see TEST_RESULT lines above)"
fi
echo ""

echo "Test 2: panel wiring in index.html and dashboard.js..."
for id in feedCompletionSection feedCompletionList feedRollupBadge feedPanelDate; do
    if grep -q "id=\"$id\"" "$INDEX_HTML"; then
        pass_test "index.html carries #$id"
    else
        fail_test "index.html is missing #$id"
    fi
done
if grep -q 'fetchFeedCompletion(timestamp, true)' "$DASHBOARD" \
    && grep -q 'fetchFeedCompletion(timestamp)' "$DASHBOARD"; then
    pass_test "both data-load paths refresh the feeds panel"
else
    fail_test "a data-load path does not refresh the feeds panel"
fi
if grep -q 'No trading day' "$DASHBOARD"; then
    pass_test "non-trading days render a friendly empty state"
else
    fail_test "no non-trading-day empty state in the renderer"
fi
# Every interpolated row field must go through escapeHtml (XSS discipline the
# dashboard already enforces — see test-xss-prevention.sh). A line that
# interpolates a row field is only safe when that line routes it through
# escapeHtml.
if grep -A40 'const rowsHtml = rows.map' "$DASHBOARD" \
    | grep -E '\$\{row\.(label|name|text|message|detail|log)\}' \
    | grep -qv 'escapeHtml'; then
    fail_test "a feed row field is interpolated without escapeHtml"
else
    pass_test "feed row fields are escaped"
fi
echo ""

echo "======================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
