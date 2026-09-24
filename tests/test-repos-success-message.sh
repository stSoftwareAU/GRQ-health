#!/bin/bash
# Test for GRQ#4851: a SUCCESS record can carry a one-line message (the run id
# that landed), so the score-publish row says WHICH run landed, not just when.
#
# Before this change `--message` was honoured only in `--failed` mode, so
# `update_repos_json_success()` wrote `last_commit_ts` and nothing else and an
# operator had to grep the host's phase log to find the run id.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_SCRIPT="$SCRIPT_DIR/../helpers/repos.sh"
# shellcheck source=tests/extract-functions.sh
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #4851: success mode records the run id"
echo "===================================================="
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

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# A project root holding a repos.json with one known entry, and a copy of the
# real repos.sh so the shipped script is what runs.
setup_test_env() {
    local test_dir="$TMPDIR_BASE/test_$$_$RANDOM"
    mkdir -p "$test_dir/docs" "$test_dir/helpers"

    cat > "$test_dir/docs/repos.json" <<'ENDJSON'
{
  "repos": [
    {
      "name": "score-publish",
      "last_commit_ts": 1776265324
    }
  ]
}
ENDJSON

    cp "$REPOS_SCRIPT" "$test_dir/helpers/repos.sh"
    chmod +x "$test_dir/helpers/repos.sh"

    echo "$test_dir"
}

entry_field() {
    jq -r ".repos[] | select(.name == \"$2\") | .$3 // empty" "$1/docs/repos.json"
}

# --------------------------------------------------------------------------
# Test 1: success --message records last_commit_message on an existing entry
# --------------------------------------------------------------------------
echo "Test 1: success --message records last_commit_message..."
TEST_DIR=$(setup_test_env)
RUN_ID="grq-3: published run scores-2026-09-24-20260924T031500Z"

bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" \
    "score-publish" --message "$RUN_ID" 2>/dev/null

MESSAGE=$(entry_field "$TEST_DIR" "score-publish" "last_commit_message")
if [ "$MESSAGE" = "$RUN_ID" ]; then
    pass_test "success --message wrote last_commit_message"
else
    fail_test "last_commit_message missing or wrong (got: '$MESSAGE')"
fi

COMMIT_TS=$(entry_field "$TEST_DIR" "score-publish" "last_commit_ts")
if [ "$COMMIT_TS" -gt 1776265324 ] 2>/dev/null; then
    pass_test "success --message still stamps last_commit_ts ($COMMIT_TS)"
else
    fail_test "success --message did not stamp last_commit_ts (got: $COMMIT_TS)"
fi

FAILURE_MESSAGE=$(entry_field "$TEST_DIR" "score-publish" "last_failure_message")
if [ -z "$FAILURE_MESSAGE" ]; then
    pass_test "success --message does not write last_failure_message"
else
    fail_test "success --message leaked into last_failure_message: $FAILURE_MESSAGE"
fi

# --------------------------------------------------------------------------
# Test 2: a NEW entry created by success --message carries the message too
# --------------------------------------------------------------------------
echo "Test 2: a new repo entry carries last_commit_message..."
TEST_DIR=$(setup_test_env)

bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" \
    "fresh-feed" --message "grq-9: published run scores-1" 2>/dev/null

MESSAGE=$(entry_field "$TEST_DIR" "fresh-feed" "last_commit_message")
if [ "$MESSAGE" = "grq-9: published run scores-1" ]; then
    pass_test "new entry carries last_commit_message"
else
    fail_test "new entry missing last_commit_message (got: '$MESSAGE')"
fi

NEW_TS=$(entry_field "$TEST_DIR" "fresh-feed" "last_commit_ts")
if [ "$NEW_TS" -gt 0 ] 2>/dev/null; then
    pass_test "new entry carries last_commit_ts ($NEW_TS)"
else
    fail_test "new entry missing last_commit_ts"
fi

# --------------------------------------------------------------------------
# Test 3: a success WITHOUT --message clears a stale message
# --------------------------------------------------------------------------
# A fresh timestamp beside the previous run's id would answer "which run"
# wrongly — worse than answering nothing.
echo "Test 3: a success without --message clears a stale message..."
TEST_DIR=$(setup_test_env)
jq '.repos |= map(if .name == "score-publish" then .last_commit_message = "grq-3: published run scores-OLD" else . end)' \
    "$TEST_DIR/docs/repos.json" > "$TEST_DIR/docs/repos.json.tmp"
mv "$TEST_DIR/docs/repos.json.tmp" "$TEST_DIR/docs/repos.json"

bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" \
    "score-publish" 2>/dev/null

MESSAGE=$(entry_field "$TEST_DIR" "score-publish" "last_commit_message")
if [ -z "$MESSAGE" ]; then
    pass_test "a message-less success cleared the stale last_commit_message"
else
    fail_test "stale last_commit_message survived a message-less success: $MESSAGE"
fi

# --------------------------------------------------------------------------
# Test 4: --failed --message still records last_failure_message only
# --------------------------------------------------------------------------
echo "Test 4: --failed --message is unchanged..."
TEST_DIR=$(setup_test_env)
LOG_FILE="$TMPDIR_BASE/run.log"
echo "publisher refused" > "$LOG_FILE"

bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" \
    "score-publish" --failed --log "$LOG_FILE" --exit-code 2 \
    --message "grq-3: endpoint unset" 2>/dev/null

FAILURE_MESSAGE=$(entry_field "$TEST_DIR" "score-publish" "last_failure_message")
if [ "$FAILURE_MESSAGE" = "grq-3: endpoint unset" ]; then
    pass_test "--failed --message still writes last_failure_message"
else
    fail_test "--failed --message broken (got: '$FAILURE_MESSAGE')"
fi

COMMIT_MESSAGE=$(entry_field "$TEST_DIR" "score-publish" "last_commit_message")
if [ -z "$COMMIT_MESSAGE" ]; then
    pass_test "--failed --message does not write last_commit_message"
else
    fail_test "--failed --message leaked into last_commit_message: $COMMIT_MESSAGE"
fi

COMMIT_TS=$(entry_field "$TEST_DIR" "score-publish" "last_commit_ts")
if [ "$COMMIT_TS" = "1776265324" ]; then
    pass_test "--failed still leaves last_commit_ts alone"
else
    fail_test "--failed moved last_commit_ts (got: $COMMIT_TS)"
fi

# --------------------------------------------------------------------------
# Test 5: the dashboard row renders the message beside the timestamp
# --------------------------------------------------------------------------
echo "Test 5: buildLastCommitHtml renders the message beside the timestamp..."
RENDER_OUTPUT=$(run_js_test '
const withMessage = buildLastCommitHtml({
    last_commit_ts: Math.floor(Date.now() / 1000) - 60,
    last_commit_message: "grq-3: published run scores-2026-09-24-1"
});
console.log("TEST_RESULT:renders_message:" +
    (withMessage.includes("Last commit") &&
     withMessage.includes("grq-3: published run scores-2026-09-24-1")
        ? "PASS" : "FAIL") + ":" + withMessage);

const withoutMessage = buildLastCommitHtml({
    last_commit_ts: Math.floor(Date.now() / 1000) - 60
});
console.log("TEST_RESULT:no_message:" +
    (withoutMessage.includes("Last commit") &&
     !withoutMessage.includes("repo-commit-message")
        ? "PASS" : "FAIL") + ":" + withoutMessage);

const missingTs = buildLastCommitHtml({ last_commit_message: "grq-3: published run x" });
console.log("TEST_RESULT:missing_ts:" +
    (missingTs.includes("Commit time unavailable") ? "PASS" : "FAIL") + ":" + missingTs);

const hostile = buildLastCommitHtml({
    last_commit_ts: Math.floor(Date.now() / 1000) - 60,
    last_commit_message: "<img src=x onerror=alert(1)>"
});
console.log("TEST_RESULT:escapes_html:" +
    (!hostile.includes("<img") && hostile.includes("&lt;img") ? "PASS" : "FAIL") + ":" + hostile);
' 2>&1) || true

for CASE_NAME in renders_message no_message missing_ts escapes_html; do
    CASE_LINE=$(echo "$RENDER_OUTPUT" | grep "^TEST_RESULT:${CASE_NAME}:" | head -1)
    if [[ "$CASE_LINE" == *":PASS:"* ]]; then
        pass_test "dashboard ${CASE_NAME}"
    else
        fail_test "dashboard ${CASE_NAME} (${CASE_LINE:-no output: $RENDER_OUTPUT})"
    fi
done

echo ""
echo "================================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
