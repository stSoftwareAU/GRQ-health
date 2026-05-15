#!/bin/bash
# Test for Issue #117: Must gracefully handle GH rate limits and network issues
#
# Verifies that:
#   1. helpers/git-retry.sh exposes the documented helpers and they behave.
#   2. After all push retries are exhausted, the local repo is reset to
#      origin so a subsequent service update does not commit on top of the
#      stale unpushed commit (which would falsely mark the previous service
#      as alive).
#   3. When push retries are exhausted, run.sh's commit_and_push exits
#      non-zero so the failure is observable.
#   4. helpers/repos.sh exits non-zero when push retries are exhausted.
#   5. Rate-limit responses trigger a sleep based on the reset window
#      (probed via the GRQ_RATE_LIMIT_SLEEP_OVERRIDE hook).
#   6. Backoff between retries follows the configured (1s, 4s, 16s) sequence.
#   7. Default retry budget is 5 attempts over "1 4 16 30 60" (Issue #125).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GIT_RETRY_LIB="$PROJECT_ROOT/helpers/git-retry.sh"
REPOS_SCRIPT="$PROJECT_ROOT/helpers/repos.sh"
RUN_SH="$PROJECT_ROOT/run.sh"

echo "Testing Issue #117: Graceful handling of GH rate limits and network issues"
echo "=========================================================================="
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

WORK_BASE=$(mktemp -d)
trap 'rm -rf "$WORK_BASE"' EXIT

export GIT_AUTHOR_NAME="Test"
export GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test"
export GIT_COMMITTER_EMAIL="test@example.com"

# --------------------------------------------------------------------------
# Test 1: git-retry.sh helpers exist and behave
# --------------------------------------------------------------------------
echo "Test 1: git-retry.sh helpers behave correctly..."
# shellcheck disable=SC1090
source "$GIT_RETRY_LIB"

if [ "$(grq_git_timeout_secs)" = "120" ]; then
    pass_test "default git timeout is 120s"
else
    fail_test "expected 120s git timeout, got: $(grq_git_timeout_secs)"
fi

if GRQ_GIT_TIMEOUT_OVERRIDE=7 grq_git_timeout_secs | grep -q "^7$"; then
    pass_test "GRQ_GIT_TIMEOUT_OVERRIDE is honoured"
else
    fail_test "GRQ_GIT_TIMEOUT_OVERRIDE not honoured"
fi

if [ "$(grq_backoff_delays)" = "1 4 16 30 60" ]; then
    pass_test "default backoff delays are 1 4 16 30 60 (Issue #125)"
else
    fail_test "expected '1 4 16 30 60' backoff, got: $(grq_backoff_delays)"
fi

if [ "$(grq_max_push_attempts)" = "5" ]; then
    pass_test "default max push attempts is 5 (Issue #125)"
else
    fail_test "expected 5 max push attempts, got: $(grq_max_push_attempts)"
fi

# Sanity: the override still works for both.
if [ "$(GRQ_PUSH_RETRY_DELAYS_OVERRIDE='0 0' grq_backoff_delays)" = "0 0" ]; then
    pass_test "GRQ_PUSH_RETRY_DELAYS_OVERRIDE is honoured"
else
    fail_test "GRQ_PUSH_RETRY_DELAYS_OVERRIDE not honoured"
fi

if [ "$(GRQ_PUSH_MAX_ATTEMPTS=2 grq_max_push_attempts)" = "2" ]; then
    pass_test "GRQ_PUSH_MAX_ATTEMPTS is honoured"
else
    fail_test "GRQ_PUSH_MAX_ATTEMPTS not honoured"
fi

if echo "remote: error: API rate limit exceeded" | grq_is_rate_limit_error; then
    pass_test "rate-limit error text is detected"
else
    fail_test "rate-limit error text was not detected"
fi

if echo "fatal: unable to access" | grq_is_rate_limit_error; then
    fail_test "non rate-limit error misdetected as rate limit"
else
    pass_test "non rate-limit error is not misdetected"
fi

# Override path: ensure the deterministic sleep value is returned.
SLEEP_SECS=$(GRQ_RATE_LIMIT_SLEEP_OVERRIDE=42 grq_rate_limit_sleep_secs 60)
if [ "$SLEEP_SECS" = "42" ]; then
    pass_test "GRQ_RATE_LIMIT_SLEEP_OVERRIDE is honoured"
else
    fail_test "expected 42s sleep override, got: $SLEEP_SECS"
fi

# --------------------------------------------------------------------------
# Helper: build a real working clone with a bare remote.
# --------------------------------------------------------------------------
setup_clone() {
    local base="$1"
    local remote="${base}/remote.git"
    local upstream="${base}/upstream"
    local work="${base}/work"

    git init --bare --initial-branch=main "$remote" >/dev/null 2>&1
    git clone --quiet "$remote" "$upstream" >/dev/null 2>&1
    mkdir -p "$upstream/docs" "$upstream/helpers"
    echo '{"repos": []}' > "$upstream/docs/repos.json"
    cp "$REPOS_SCRIPT" "$upstream/helpers/repos.sh"
    cp "$GIT_RETRY_LIB" "$upstream/helpers/git-retry.sh"
    chmod +x "$upstream/helpers/repos.sh" "$upstream/helpers/git-retry.sh"
    (
        cd "$upstream"
        git add docs helpers >/dev/null 2>&1
        git commit -m "initial" --quiet >/dev/null 2>&1
        git push --quiet origin HEAD:main >/dev/null 2>&1
    )

    git clone --quiet "$remote" "$work" >/dev/null 2>&1
    (
        cd "$work"
        git checkout -q main
    )
    echo "$work"
}

# --------------------------------------------------------------------------
# Test 2: repos.sh exits non-zero when push fails for all retries
# --------------------------------------------------------------------------
echo ""
echo "Test 2: repos.sh exits non-zero when all push attempts fail..."
T2_BASE="${WORK_BASE}/t2"
mkdir -p "$T2_BASE"
WORK=$(setup_clone "$T2_BASE")

# Break the remote so push always fails
(cd "$WORK" && git remote set-url origin "${T2_BASE}/no-such-remote.git")

set +e
GRQ_PUSH_RETRY_DELAYS_OVERRIDE="0 0 0" \
    "$WORK/helpers/repos.sh" "Net" --skip-rate-limit --project-root "$WORK" \
    >"${T2_BASE}/out.log" 2>&1
EXIT=$?
set -e

if [ "$EXIT" -ne 0 ]; then
    pass_test "repos.sh exit code is non-zero on persistent push failure ($EXIT)"
else
    fail_test "repos.sh exited 0 on persistent push failure"
fi

# --------------------------------------------------------------------------
# Test 3: After repos.sh push exhaustion, working clone matches origin
#         (no stale local commit blocking the next service's update).
# --------------------------------------------------------------------------
echo ""
echo "Test 3: repos.sh resets working clone to origin after exhausted retries..."
T3_BASE="${WORK_BASE}/t3"
mkdir -p "$T3_BASE"
WORK=$(setup_clone "$T3_BASE")
T3_REMOTE="${T3_BASE}/remote.git"

# Snapshot the origin HEAD before the failed run.
ORIGIN_HEAD_BEFORE=$(cd "$T3_REMOTE" && git rev-parse main 2>/dev/null)

# Point at a dead remote so push fails for all 3 attempts.
(cd "$WORK" && git remote set-url origin "${T3_BASE}/no-such-remote.git")

set +e
GRQ_PUSH_RETRY_DELAYS_OVERRIDE="0 0 0" \
    "$WORK/helpers/repos.sh" "DeadService" --skip-rate-limit --project-root "$WORK" \
    >"${T3_BASE}/out.log" 2>&1
set -e

# Restore the working remote so we can compare against the real origin.
(cd "$WORK" && git remote set-url origin "$T3_REMOTE" && git fetch --quiet origin main)

WORK_HEAD=$(cd "$WORK" && git rev-parse HEAD)
UNPUSHED=$(cd "$WORK" && git rev-list --count "origin/main..HEAD" 2>/dev/null || echo "?")
DIRTY=$(cd "$WORK" && git status --porcelain)

if [ "$WORK_HEAD" = "$ORIGIN_HEAD_BEFORE" ]; then
    pass_test "working clone HEAD reset to origin/main after exhausted retries"
else
    fail_test "working clone HEAD ($WORK_HEAD) does not match origin ($ORIGIN_HEAD_BEFORE)"
fi

if [ "$UNPUSHED" = "0" ]; then
    pass_test "no stale unpushed commit remains after exhausted retries"
else
    fail_test "expected 0 unpushed commits, got: $UNPUSHED"
fi

if [ -z "$DIRTY" ]; then
    pass_test "working tree is clean after exhausted retries"
else
    fail_test "working tree dirty after exhausted retries: $DIRTY"
fi

# Output should mention reset/recovery so operators can see what happened.
if grep -Eiq "reset|recover|discard" "${T3_BASE}/out.log"; then
    pass_test "repos.sh logs the reset/recovery action"
else
    fail_test "repos.sh did not log reset/recovery"
fi

# --------------------------------------------------------------------------
# Test 4: rate-limit response triggers a sleep matching the override
# --------------------------------------------------------------------------
echo ""
echo "Test 4: rate-limit response triggers configurable sleep..."
T4_BASE="${WORK_BASE}/t4"
mkdir -p "$T4_BASE"
WORK=$(setup_clone "$T4_BASE")

# Mock git so the first push prints a rate-limit error and the second succeeds.
MOCK_BIN="${T4_BASE}/mock_bin"
mkdir -p "$MOCK_BIN"
PUSH_COUNT_FILE="${T4_BASE}/push_count"
echo "0" > "$PUSH_COUNT_FILE"
SLEEP_LOG="${T4_BASE}/sleep_log"
: > "$SLEEP_LOG"

REAL_GIT=$(command -v git)
cat > "${MOCK_BIN}/git" <<MOCKEOF
#!/bin/bash
if [ "\$1" = "push" ]; then
    count=\$(cat "$PUSH_COUNT_FILE")
    count=\$((count + 1))
    echo "\$count" > "$PUSH_COUNT_FILE"
    if [ "\$count" -le 1 ]; then
        echo "remote: error: API rate limit exceeded for user." >&2
        exit 1
    fi
    exec "$REAL_GIT" "\$@"
fi
exec "$REAL_GIT" "\$@"
MOCKEOF
chmod +x "${MOCK_BIN}/git"

# Mock sleep so we can record the requested sleep duration without waiting.
cat > "${MOCK_BIN}/sleep" <<SLEEPEOF
#!/bin/bash
echo "\$1" >> "$SLEEP_LOG"
exit 0
SLEEPEOF
chmod +x "${MOCK_BIN}/sleep"

set +e
PATH="${MOCK_BIN}:${PATH}" \
    GRQ_PUSH_RETRY_DELAYS_OVERRIDE="0 0 0" \
    GRQ_RATE_LIMIT_SLEEP_OVERRIDE=37 \
    "$WORK/helpers/repos.sh" "RateLimited" --skip-rate-limit --project-root "$WORK" \
    >"${T4_BASE}/out.log" 2>&1
EXIT=$?
set -e

if grep -q "^37$" "$SLEEP_LOG"; then
    pass_test "rate-limit sleep used the override (37s)"
else
    fail_test "expected 37s sleep recorded, got: $(cat "$SLEEP_LOG")"
fi

if [ "$EXIT" -eq 0 ]; then
    pass_test "repos.sh succeeded after rate-limit pause + retry"
else
    fail_test "repos.sh exited $EXIT after rate-limit pause + retry. Output: $(cat "${T4_BASE}/out.log")"
fi

if grep -Eiq "rate.limit" "${T4_BASE}/out.log"; then
    pass_test "repos.sh logged the rate-limit detection"
else
    fail_test "repos.sh did not log rate-limit detection. Output: $(cat "${T4_BASE}/out.log")"
fi

# --------------------------------------------------------------------------
# Test 5: backoff between retries follows the configured sequence
# --------------------------------------------------------------------------
echo ""
echo "Test 5: backoff sleeps follow the configured sequence..."
T5_BASE="${WORK_BASE}/t5"
mkdir -p "$T5_BASE"
WORK=$(setup_clone "$T5_BASE")

MOCK_BIN5="${T5_BASE}/mock_bin"
mkdir -p "$MOCK_BIN5"
SLEEP_LOG5="${T5_BASE}/sleep_log"
: > "$SLEEP_LOG5"

# Mock git to fail every push with a non-rate-limit error.
cat > "${MOCK_BIN5}/git" <<MOCKEOF
#!/bin/bash
if [ "\$1" = "push" ]; then
    echo "fatal: unable to access remote" >&2
    exit 1
fi
exec "$REAL_GIT" "\$@"
MOCKEOF
chmod +x "${MOCK_BIN5}/git"

cat > "${MOCK_BIN5}/sleep" <<SLEEPEOF
#!/bin/bash
echo "\$1" >> "$SLEEP_LOG5"
exit 0
SLEEPEOF
chmod +x "${MOCK_BIN5}/sleep"

set +e
PATH="${MOCK_BIN5}:${PATH}" \
    GRQ_PUSH_RETRY_DELAYS_OVERRIDE="2 5 11" \
    "$WORK/helpers/repos.sh" "BackoffSvc" --skip-rate-limit --project-root "$WORK" \
    >"${T5_BASE}/out.log" 2>&1
set -e

# With 3 attempts and the rebase recovery branch, sleeps occur after each
# failed attempt (except the last). Both attempt-1 and attempt-2 must use
# the configured backoff values.
if grep -q "^2$" "$SLEEP_LOG5" && grep -q "^5$" "$SLEEP_LOG5"; then
    pass_test "backoff sleeps used the configured 2s and 5s values"
else
    fail_test "expected 2 and 5 in sleep log, got: $(cat "$SLEEP_LOG5")"
fi

# --------------------------------------------------------------------------
# Test 6: run.sh's commit_and_push exits non-zero on persistent push failure
#         and resets the working clone.
# --------------------------------------------------------------------------
echo ""
echo "Test 6: run.sh commit_and_push exits non-zero and resets on push failure..."
T6_BASE="${WORK_BASE}/t6"
mkdir -p "$T6_BASE"
WORK=$(setup_clone "$T6_BASE")

# Stage an uncommitted change in docs/ so commit_and_push has something to
# commit (the same shape as a real heartbeat update).
(
    cd "$WORK"
    mkdir -p docs
    echo '{"hostname": "TEST"}' > docs/index.json
    git add docs/index.json >/dev/null 2>&1
    git commit -m "seed" --quiet >/dev/null 2>&1
    git push --quiet origin HEAD:main >/dev/null 2>&1
    echo '{"hostname": "TEST", "stale": true}' > docs/index.json
)

# Snapshot origin head so we can verify the reset target later.
ORIGIN_HEAD_BEFORE=$(cd "${T6_BASE}/remote.git" && git rev-parse main)

# Break the remote so push always fails.
(cd "$WORK" && git remote set-url origin "${T6_BASE}/no-such-remote.git")

# Source run.sh's commit_and_push function in a sub-shell so we can
# observe its exit code.
set +e
(
    cd "$WORK"
    HOSTNAME="TEST"
    # CURRENT_TS and NO_GIT are read by the eval'd commit_and_push function.
    # shellcheck disable=SC2034
    CURRENT_TS=$(date +%s)
    # shellcheck disable=SC2034
    NO_GIT=false
    # Source the git-retry helpers so commit_and_push can use them.
    # shellcheck disable=SC1090
    source "$GIT_RETRY_LIB"
    eval "$(sed -n '/^commit_and_push()/,/^}/p' "$RUN_SH")"
    GRQ_PUSH_RETRY_DELAYS_OVERRIDE="0 0 0" commit_and_push
) >"${T6_BASE}/out.log" 2>&1
EXIT=$?
set -e

if [ "$EXIT" -ne 0 ]; then
    pass_test "run.sh commit_and_push exits non-zero on persistent push failure ($EXIT)"
else
    fail_test "run.sh commit_and_push exited 0 on persistent push failure"
fi

# Restore the working remote and verify the working clone reset back to it.
(cd "$WORK" && git remote set-url origin "${T6_BASE}/remote.git" && git fetch --quiet origin main)
WORK_HEAD=$(cd "$WORK" && git rev-parse HEAD)
UNPUSHED=$(cd "$WORK" && git rev-list --count "origin/main..HEAD" 2>/dev/null || echo "?")

if [ "$WORK_HEAD" = "$ORIGIN_HEAD_BEFORE" ]; then
    pass_test "run.sh resets working clone to origin after exhausted push retries"
else
    fail_test "working clone HEAD ($WORK_HEAD) != origin HEAD ($ORIGIN_HEAD_BEFORE)"
fi

if [ "$UNPUSHED" = "0" ]; then
    pass_test "no unpushed commit remains after run.sh exhausts retries"
else
    fail_test "expected 0 unpushed commits, got: $UNPUSHED"
fi

if grep -Eiq "reset|discard|recover" "${T6_BASE}/out.log"; then
    pass_test "run.sh logs the reset/recovery action"
else
    fail_test "run.sh did not log reset/recovery"
fi

# --------------------------------------------------------------------------
echo ""
echo "=========================================================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
