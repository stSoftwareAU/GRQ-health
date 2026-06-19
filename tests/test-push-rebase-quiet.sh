#!/bin/bash
# Test for Issue #2754: quiet, info-level logging of an expected
# non-fast-forward push rejection on the shared health branch.
#
# When another host pushes to GRQ-health concurrently, our push is rejected
# as a non-fast-forward ("fetch first") and self-recovers via pull --rebase.
# That recovery is routine, so commit_and_push() must log it at info level
# WITHOUT echoing the alarming raw git stderr (`error:` / `! [rejected]`).
# A genuinely unexpected push failure must still log the loud "Push failed"
# line so true problems stay observable.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"
GIT_RETRY_LIB="$SCRIPT_DIR/../helpers/git-retry.sh"

# shellcheck disable=SC1090
. "$GIT_RETRY_LIB"

# Speed the retry loop up so the test does not wait on real backoff delays.
export GRQ_PUSH_RETRY_DELAYS_OVERRIDE="0 0 0"

echo "Testing Issue #2754: quiet non-fast-forward push logging"
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

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

setup_fake_repo() {
    local dir="$1"
    local remote_dir="${dir}/remote.git"
    git init --bare "$remote_dir" >/dev/null 2>&1

    local work_dir="${dir}/work"
    mkdir -p "$work_dir/docs"
    cd "$work_dir"
    git init >/dev/null 2>&1
    git remote add origin "$remote_dir" >/dev/null 2>&1
    echo '{}' > docs/index.json
    git add docs/ >/dev/null 2>&1
    git commit -m "initial" >/dev/null 2>&1
    git push -u origin HEAD >/dev/null 2>&1
    echo '{"test": true}' > docs/index.json
    echo "$work_dir"
}

# Build a mock git that fails the first push with a caller-supplied stderr
# blob, succeeds on the second push, and delegates every other command to the
# real git binary.
make_first_push_fail_mock() {
    local mock_bin="$1"
    local count_file="$2"
    local stderr_blob="$3"
    mkdir -p "$mock_bin"
    echo "0" > "$count_file"
    local real_git
    real_git=$(which git)

    cat > "${mock_bin}/git" <<MOCKEOF
#!/bin/bash
COUNT_FILE="${count_file}"
REAL_GIT="${real_git}"
if [ "\$1" = "push" ]; then
    count=\$(cat "\$COUNT_FILE")
    count=\$((count + 1))
    echo "\$count" > "\$COUNT_FILE"
    if [ "\$count" -le 1 ]; then
        cat >&2 <<'STDERR_EOF'
${stderr_blob}
STDERR_EOF
        exit 1
    fi
    exit 0
fi
"\$REAL_GIT" "\$@"
MOCKEOF
    chmod +x "${mock_bin}/git"
}

# ---------------------------------------------------------------------------
# Test 1: a non-fast-forward rejection is logged quietly (info level).
# ---------------------------------------------------------------------------
echo "Test 1: non-fast-forward rejection logs quietly..."
T1="${WORK_DIR}/t1"
mkdir -p "$T1"
REPO_DIR=$(setup_fake_repo "$T1")
cd "$REPO_DIR"
echo '{"test": "nff"}' > docs/index.json

NFF_STDERR='To github.com:stSoftwareAU/GRQ-health.git
 ! [rejected]        Develop -> Develop (fetch first)
error: failed to push some refs to '\''github.com:stSoftwareAU/GRQ-health.git'\''
hint: Updates were rejected because the remote contains work that you do'
make_first_push_fail_mock "${T1}/mock_bin" "${T1}/push_count" "$NFF_STDERR"

# shellcheck disable=SC2034
HOSTNAME="TEST-HOST"
# shellcheck disable=SC2034
CURRENT_TS=$(date +%s)
# shellcheck disable=SC2034
NO_GIT=false
eval "$(sed -n '/^commit_and_push()/,/^}/p' "$RUN_SH")"

OUTPUT=$(PATH="${T1}/mock_bin:${PATH}" commit_and_push 2>&1)

if echo "$OUTPUT" | grep -q "Info: remote advanced"; then
    pass_test "info-level concurrent-push message logged"
else
    fail_test "Expected 'Info: remote advanced' message, got: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "Push failed (attempt"; then
    fail_test "Loud 'Push failed (attempt' line should be suppressed for non-ff, got: $OUTPUT"
else
    pass_test "loud 'Push failed (attempt' line suppressed for non-ff rejection"
fi

if echo "$OUTPUT" | grep -q "\! \[rejected\]"; then
    fail_test "Raw '! [rejected]' git stderr should not be echoed, got: $OUTPUT"
else
    pass_test "raw '! [rejected]' git stderr not echoed"
fi

if echo "$OUTPUT" | grep -q "Changes pushed to remote repository"; then
    pass_test "push succeeded after quiet pull --rebase recovery"
else
    fail_test "Expected successful push after recovery, got: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Test 2: a genuinely unexpected failure still logs the loud line.
# ---------------------------------------------------------------------------
echo "Test 2: unexpected failure still logs loudly..."
T2="${WORK_DIR}/t2"
mkdir -p "$T2"
REPO_DIR=$(setup_fake_repo "$T2")
cd "$REPO_DIR"
echo '{"test": "net"}' > docs/index.json

NET_STDERR='fatal: unable to access '\''https://github.com/stSoftwareAU/GRQ-health.git/'\'': Could not resolve host: github.com'
make_first_push_fail_mock "${T2}/mock_bin" "${T2}/push_count" "$NET_STDERR"

# shellcheck disable=SC2034
CURRENT_TS=$(date +%s)
eval "$(sed -n '/^commit_and_push()/,/^}/p' "$RUN_SH")"

OUTPUT2=$(PATH="${T2}/mock_bin:${PATH}" commit_and_push 2>&1)

if echo "$OUTPUT2" | grep -q "Push failed (attempt"; then
    pass_test "loud 'Push failed (attempt' line retained for unexpected failure"
else
    fail_test "Expected loud 'Push failed (attempt' line for unexpected failure, got: $OUTPUT2"
fi

if echo "$OUTPUT2" | grep -q "Info: remote advanced"; then
    fail_test "Should not log concurrent-push info for an unexpected failure, got: $OUTPUT2"
else
    pass_test "concurrent-push info not logged for unexpected failure"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
