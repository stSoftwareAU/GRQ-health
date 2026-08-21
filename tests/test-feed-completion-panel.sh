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
    | grep -E '\$\{row\.(label|name|text|message|detail|log|host|user)\}' \
    | grep -qv 'escapeHtml'; then
    fail_test "a feed row field is interpolated without escapeHtml"
else
    pass_test "feed row fields are escaped"
fi
# The time line carries host and user, so the renderer must route the whole
# formatted line through escapeHtml (GRQ#4223).
if grep -q 'escapeHtml(formatFeedRowWhen(row))' "$DASHBOARD"; then
    pass_test "the feed row time line is escaped before it reaches the DOM"
else
    fail_test "the feed row time line is not routed through escapeHtml"
fi
echo ""

echo "Test 3: the publishing user account is named on every feed row (GRQ#4223)..."
OUTPUT=$(run_js_test '
function t(name, ok, detail) {
    console.log(`TEST_RESULT:${name}:${ok ? "PASS" : "FAIL"}:${detail}`);
}

// One host, several accounts — the case the panel exists to make legible.
// sentiment-tickers has no `user` (a day file written before the field
// existed) and sentiment-topics has an empty one; both must read as they did
// before GRQ#4223.
const day = { ny_date: "20260820", feeds: {
    "shareprices": { status: "complete", ts: 100, host: "Mac-Ultra-M2", user: "alice" },
    "commodities": { status: "no-change", ts: 101, host: "Mac-Ultra-M2", user: "bob" },
    "insiders": { status: "failed", ts: 102, host: "Mac-Ultra-M2", user: "carol",
                  exit_code: 3, message: "Push failed", log: "logs/Insiders/20260820-1.log" },
    "sentiment-tickers": { status: "complete", ts: 103, host: "GRQ-11" },
    "sentiment-topics": { status: "no-change", ts: 104, host: "GRQ-11", user: "" },
}};
const byName = Object.fromEntries(buildFeedRows(day, 5).map(r => [r.name, r]));

// 1. The row builder carries the user of that entry through, for all three states.
t("row-user-complete", byName["shareprices"].user === "alice", "complete row exposes the entry user");
t("row-user-no-change", byName["commodities"].user === "bob", "no-change row exposes the entry user");
t("row-user-failed", byName["insiders"].user === "carol", "failed row exposes the entry user");

// 2. The rendered time line names host and user together.
const completeText = formatFeedRowWhen(byName["shareprices"]);
const noChangeText = formatFeedRowWhen(byName["commodities"]);
const failedText = formatFeedRowWhen(byName["insiders"]);
t("text-complete", completeText.includes("on Mac-Ultra-M2") && completeText.includes("(alice)"), `complete row reads ${completeText}`);
t("text-no-change", noChangeText.includes("on Mac-Ultra-M2") && noChangeText.includes("(bob)"), `no-change row reads ${noChangeText}`);
t("text-failed", failedText.includes("on Mac-Ultra-M2") && failedText.includes("(carol)"), `failed row reads ${failedText}`);

// 3. Two accounts on one host are told apart — a wrong attribution (both rows
//    showing the same user) is worse than none.
t("text-per-row-user", completeText.includes("(alice)") && !completeText.includes("(bob)")
    && noChangeText.includes("(bob)") && !noChangeText.includes("(alice)"),
    "each row shows its own account, not a shared one");

// 4. Day files without the field degrade gracefully: no "()", no "undefined".
const legacyText = formatFeedRowWhen(byName["sentiment-tickers"]);
const emptyUserText = formatFeedRowWhen(byName["sentiment-topics"]);
t("text-no-user", legacyText.includes("on GRQ-11") && !legacyText.includes("(") && !legacyText.includes("undefined"),
    `missing user renders unchanged: ${legacyText}`);
t("text-empty-user", emptyUserText.includes("on GRQ-11") && !emptyUserText.includes("(") && !emptyUserText.includes("undefined"),
    `empty user renders unchanged: ${emptyUserText}`);

// 5. The failed row keeps its exit code, message and log link.
t("failed-affordances", byName["insiders"].exitCode === 3 && byName["insiders"].message === "Push failed"
    && buildLogViewerUrl(byName["insiders"].log).length > 0,
    "failed row still carries exit code, message and log link");

// 6. A hostile user value is escaped, never injected.
const hostile = buildFeedRow({ name: "shareprices", label: "Share prices" },
    { status: "complete", ts: 105, host: "GRQ-11", user: `<img src=x onerror="alert(1)">` }, 5);
const hostileHtml = escapeHtml(formatFeedRowWhen(hostile));
t("user-escaped", !hostileHtml.includes("<img") && hostileHtml.includes("&lt;img"), `hostile user escaped: ${hostileHtml}`);

// 7. A row with no timestamp (never run) is unchanged — text only.
t("missing-row-text", formatFeedRowWhen({ state: "missing", text: "not run — 5h into the NY day" }) === "not run — 5h into the NY day",
    "a not-run row still renders its text alone");
')
if check_output "$OUTPUT"; then
    pass_test "feed rows name the publishing user account per the GRQ#4223 contract"
else
    fail_test "feed row user attribution regressions (see TEST_RESULT lines above)"
fi
echo ""

echo "======================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
