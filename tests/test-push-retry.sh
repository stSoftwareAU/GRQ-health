#!/bin/bash
# Test for Issue #51: Add heartbeat update retry on push failure
# Verifies that commit_and_push retries on git push failure

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"
GIT_RETRY_LIB="$SCRIPT_DIR/../helpers/git-retry.sh"

# Issue #117: commit_and_push now uses helpers from git-retry.sh
# (grq_run_git, grq_backoff_delays, grq_recover_to_remote, etc.). Source
# the library so the extracted function can find them.
# shellcheck disable=SC1090
. "$GIT_RETRY_LIB"

# Speed the retry loop up for tests so we don't wait 1+4+16=21s per retry.
export GRQ_PUSH_RETRY_DELAYS_OVERRIDE="0 0 0"

echo "Testing Issue #51: Heartbeat push retry on failure"
echo "==================================================="
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

# Create a temporary directory to work in
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Set up a fake git repo with a remote so commit_and_push runs
setup_fake_repo() {
    local dir="$1"
    # Create a bare "remote" repo
    local remote_dir="${dir}/remote.git"
    git init --bare "$remote_dir" >/dev/null 2>&1

    # Create the working repo
    local work_dir="${dir}/work"
    mkdir -p "$work_dir/docs"
    cd "$work_dir"
    git init >/dev/null 2>&1
    git remote add origin "$remote_dir" >/dev/null 2>&1
    # Initial commit
    echo '{}' > docs/index.json
    git add docs/ >/dev/null 2>&1
    git commit -m "initial" >/dev/null 2>&1
    git push -u origin HEAD >/dev/null 2>&1
    # Make a change for commit_and_push to find
    echo '{"test": true}' > docs/index.json
    echo "$work_dir"
}

# Test 1: Push succeeds on first try — no retry needed
echo "Test 1: Push succeeds on first try..."
TEST1_DIR="${WORK_DIR}/test1"
mkdir -p "$TEST1_DIR"
REPO_DIR=$(setup_fake_repo "$TEST1_DIR")
cd "$REPO_DIR"

# Source run.sh functions but don't execute main
HOSTNAME="TEST-HOST"
# CURRENT_TS and NO_GIT are read by the eval'd commit_and_push function from run.sh
# shellcheck disable=SC2034
CURRENT_TS=$(date +%s)
# shellcheck disable=SC2034
NO_GIT=false
# Source just the commit_and_push function
eval "$(sed -n '/^commit_and_push()/,/^}/p' "$RUN_SH")"

OUTPUT=$(commit_and_push 2>&1)
if echo "$OUTPUT" | grep -q "Changes pushed to remote repository"; then
    pass_test "Push succeeds on first try"
else
    fail_test "Expected successful push message, got: $OUTPUT"
fi

# Test 2: Push fails then succeeds on retry
echo "Test 2: Push fails once then succeeds on retry..."
TEST2_DIR="${WORK_DIR}/test2"
mkdir -p "$TEST2_DIR"
REPO_DIR=$(setup_fake_repo "$TEST2_DIR")
cd "$REPO_DIR"

# Make another change
echo '{"test": "retry"}' > docs/index.json

# Create a mock git that fails on first push, succeeds on second
MOCK_BIN="${TEST2_DIR}/mock_bin"
mkdir -p "$MOCK_BIN"
PUSH_COUNT_FILE="${TEST2_DIR}/push_count"
echo "0" > "$PUSH_COUNT_FILE"

cat > "${MOCK_BIN}/git" << 'MOCKEOF'
#!/bin/bash
PUSH_COUNT_FILE="PLACEHOLDER_COUNT_FILE"
if [ "$1" = "push" ]; then
    count=$(cat "$PUSH_COUNT_FILE")
    count=$((count + 1))
    echo "$count" > "$PUSH_COUNT_FILE"
    if [ "$count" -le 1 ]; then
        echo "error: failed to push" >&2
        exit 1
    fi
    exit 0
fi
# For all other git commands, use the real git
REAL_GIT="PLACEHOLDER_REAL_GIT"
"$REAL_GIT" "$@"
MOCKEOF

REAL_GIT=$(which git)
sed -i.bak "s|PLACEHOLDER_COUNT_FILE|${PUSH_COUNT_FILE}|g" "${MOCK_BIN}/git"
sed -i.bak "s|PLACEHOLDER_REAL_GIT|${REAL_GIT}|g" "${MOCK_BIN}/git"
chmod +x "${MOCK_BIN}/git"

CURRENT_TS=$(date +%s)
eval "$(sed -n '/^commit_and_push()/,/^}/p' "$RUN_SH")"

PATH="${MOCK_BIN}:${PATH}" OUTPUT=$(commit_and_push 2>&1)
FINAL_PUSH_COUNT=$(cat "$PUSH_COUNT_FILE")

if [ "$FINAL_PUSH_COUNT" -ge 2 ]; then
    pass_test "Push was retried after initial failure (push count: $FINAL_PUSH_COUNT)"
else
    fail_test "Expected at least 2 push attempts, got: $FINAL_PUSH_COUNT"
fi

if echo "$OUTPUT" | grep -qi "retry\|retrying"; then
    pass_test "Retry message was logged"
else
    fail_test "Expected retry message in output, got: $OUTPUT"
fi

# Test 3: Push fails all retries
echo "Test 3: Push fails all retries..."
TEST3_DIR="${WORK_DIR}/test3"
mkdir -p "$TEST3_DIR"
REPO_DIR=$(setup_fake_repo "$TEST3_DIR")
cd "$REPO_DIR"

echo '{"test": "all-fail"}' > docs/index.json

MOCK_BIN3="${TEST3_DIR}/mock_bin"
mkdir -p "$MOCK_BIN3"
PUSH_COUNT_FILE3="${TEST3_DIR}/push_count"
echo "0" > "$PUSH_COUNT_FILE3"

cat > "${MOCK_BIN3}/git" << 'MOCKEOF'
#!/bin/bash
PUSH_COUNT_FILE="PLACEHOLDER_COUNT_FILE"
if [ "$1" = "push" ]; then
    count=$(cat "$PUSH_COUNT_FILE")
    count=$((count + 1))
    echo "$count" > "$PUSH_COUNT_FILE"
    echo "error: failed to push" >&2
    exit 1
fi
REAL_GIT="PLACEHOLDER_REAL_GIT"
"$REAL_GIT" "$@"
MOCKEOF

REAL_GIT=$(which git)
sed -i.bak "s|PLACEHOLDER_COUNT_FILE|${PUSH_COUNT_FILE3}|g" "${MOCK_BIN3}/git"
sed -i.bak "s|PLACEHOLDER_REAL_GIT|${REAL_GIT}|g" "${MOCK_BIN3}/git"
chmod +x "${MOCK_BIN3}/git"

# CURRENT_TS is read by the eval'd commit_and_push function from run.sh
# shellcheck disable=SC2034
CURRENT_TS=$(date +%s)
eval "$(sed -n '/^commit_and_push()/,/^}/p' "$RUN_SH")"

# Issue #117: commit_and_push now exits non-zero when all retries are
# exhausted so the failure is observable. Capture both the output and the
# exit code via `|| true` to keep `set -e` happy.
set +e
PATH="${MOCK_BIN3}:${PATH}" OUTPUT=$(commit_and_push 2>&1)
COMMIT_PUSH_EXIT=$?
set -e
FINAL_PUSH_COUNT3=$(cat "$PUSH_COUNT_FILE3")

if [ "$FINAL_PUSH_COUNT3" -ge 3 ]; then
    pass_test "All retry attempts were made (push count: $FINAL_PUSH_COUNT3)"
else
    fail_test "Expected at least 3 push attempts, got: $FINAL_PUSH_COUNT3"
fi

if echo "$OUTPUT" | grep -qi "failed\|push failed"; then
    pass_test "Failure message logged after all retries exhausted"
else
    fail_test "Expected failure message, got: $OUTPUT"
fi

# Issue #117: confirm the function returns non-zero when push is exhausted.
if [ "$COMMIT_PUSH_EXIT" -ne 0 ]; then
    pass_test "commit_and_push exits non-zero on exhausted retries (Issue #117)"
else
    fail_test "Expected non-zero exit on exhausted retries, got: $COMMIT_PUSH_EXIT"
fi

# Summary
echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
