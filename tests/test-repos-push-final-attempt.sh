#!/bin/bash
# Test for Issue #139: helpers/repos.sh push retry loop can silently drop a
# host health update.
#
# Two defects are covered:
#   1. The final push attempt got no fetch+rebase recovery, so if the remote
#      moved during the last backoff the final attempt re-pushed a stale
#      commit and failed (status=push-failed). The fix rebases BEFORE pushing
#      on every retry, so the final attempt also pushes onto a fresh base.
#   2. A rebase conflict on docs/repos.json reset to remote, set
#      GIT_PUSH_SUCCESS=true and broke — silently dropping this host's update
#      while reporting success. The fix re-applies this host's update onto the
#      fresh base and pushes it (the update reaches the remote), rather than
#      discarding it unseen.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_SCRIPT="$SCRIPT_DIR/../helpers/repos.sh"
GIT_RETRY_LIB="$SCRIPT_DIR/../helpers/git-retry.sh"

echo "Testing Issue #139: final-attempt recovery + no silent update drop"
echo "================================================================="
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

export GIT_AUTHOR_NAME="Test"
export GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test"
export GIT_COMMITTER_EMAIL="test@example.com"

# --------------------------------------------------------------------------
# Test 1 (defect 1): the remote moves during the final backoff; the last
# attempt must still recover via fetch+rebase and push successfully.
#
# A `sleep` shim placed first on PATH deterministically advances the shared
# remote by one commit the first time repos.sh sleeps between retries — this
# emulates a concurrent fleet writer landing a commit while we back off.
# --------------------------------------------------------------------------
echo "Test 1: remote moves during final backoff — last attempt recovers..."
T1="${TMPDIR_BASE}/test1"
mkdir -p "$T1"
REMOTE1="${T1}/remote.git"
UPSTREAM1="${T1}/upstream"
WORK1="${T1}/work"

git init --bare --initial-branch=main "$REMOTE1" >/dev/null 2>&1
git clone --quiet "$REMOTE1" "$UPSTREAM1" >/dev/null 2>&1
mkdir -p "$UPSTREAM1/docs" "$UPSTREAM1/helpers"
echo '{"repos": []}' > "$UPSTREAM1/docs/repos.json"
cp "$REPOS_SCRIPT" "$UPSTREAM1/helpers/repos.sh"
cp "$GIT_RETRY_LIB" "$UPSTREAM1/helpers/git-retry.sh"
chmod +x "$UPSTREAM1/helpers/repos.sh" "$UPSTREAM1/helpers/git-retry.sh"
(
    cd "$UPSTREAM1"
    git add docs helpers >/dev/null 2>&1
    git commit -m "initial" --quiet >/dev/null 2>&1
    git push --quiet origin HEAD:main >/dev/null 2>&1
)

git clone --quiet "$REMOTE1" "$WORK1" >/dev/null 2>&1
(
    cd "$WORK1"
    git checkout -q main
    git config pull.ff only
    echo "local-only" > docs/local_only.txt
    git add docs/local_only.txt >/dev/null 2>&1
    git commit -m "local-only commit" --quiet >/dev/null 2>&1
)

# Diverge #1: a pre-push hook lands a remote-only commit at the moment of the
# FIRST push, so that push is rejected non-fast-forward.
#
# GRQ#4237 changed the injection point: this used to be a plain commit pushed
# before repos.sh ran, but the Step 1 pre-commit pull now rebases (--rebase
# --autostash) and would integrate it before the first push, so the race this
# test needs never happened. Racing the push itself reproduces the real fleet
# behaviour — a peer landing a commit between our pull and our push — and the
# assertions below are unchanged.
cat > "${WORK1}/.git/hooks/pre-push" <<HOOK
#!/bin/bash
# GRQ#4237 test injector — land a peer commit once, at first-push time.
if [ ! -f "${T1}/prepush.marker" ]; then
    touch "${T1}/prepush.marker"
    (
        cd "$UPSTREAM1" || exit 0
        git pull --quiet >/dev/null 2>&1 || true
        echo "remote-change" > docs/remote_only.txt
        git add docs/remote_only.txt >/dev/null 2>&1
        git commit -m "remote-only commit" --quiet >/dev/null 2>&1
        git push --quiet origin HEAD:main >/dev/null 2>&1
    )
fi
exit 0
HOOK
chmod +x "${WORK1}/.git/hooks/pre-push"

# Build the sleep shim: on its first invocation, land diverge #2 on the
# remote, then behave as an instant no-op sleep.
SHIM_DIR="${T1}/shim"
mkdir -p "$SHIM_DIR"
cat > "${SHIM_DIR}/sleep" <<SHIM
#!/bin/bash
# Issue #139 test injector — advances the remote once, then no-op sleep.
if [ ! -f "\$SLEEP_SHIM_MARKER" ]; then
    touch "\$SLEEP_SHIM_MARKER"
    (
        cd "\$SLEEP_SHIM_UPSTREAM" || exit 0
        git pull --quiet >/dev/null 2>&1 || true
        echo "second-remote-change" > docs/remote_only2.txt
        git add docs/remote_only2.txt >/dev/null 2>&1
        git commit -m "second remote-only commit" --quiet >/dev/null 2>&1
        git push --quiet origin HEAD:main >/dev/null 2>&1
    )
fi
exit 0
SHIM
chmod +x "${SHIM_DIR}/sleep"

OUTPUT1=$(cd "$WORK1" && \
    PATH="${SHIM_DIR}:$PATH" \
    SLEEP_SHIM_MARKER="${T1}/shim.marker" \
    SLEEP_SHIM_UPSTREAM="$UPSTREAM1" \
    GRQ_PUSH_MAX_ATTEMPTS=2 \
    GIT_PUSH_RETRY_DELAY_OVERRIDE=0 \
    ./helpers/repos.sh "FinalAttemptRepo" --skip-rate-limit --project-root "$WORK1" 2>&1 || true)

(cd "$WORK1" && git fetch --quiet 2>/dev/null || true)

# The host's health update must have reached the remote despite the remote
# moving during the final backoff. On the unfixed code the final attempt
# re-pushes a stale commit and fails, so the entry never lands.
REMOTE1_JSON=$(cd "$REMOTE1" && git show "main:docs/repos.json" 2>/dev/null || echo "")
if echo "$REMOTE1_JSON" | grep -q '"FinalAttemptRepo"'; then
    pass_test "Host update reached remote after remote moved during final backoff"
else
    fail_test "FinalAttemptRepo missing on remote. json='$REMOTE1_JSON' output: $OUTPUT1"
fi

# The concurrent commit that landed during the backoff must be preserved
# (proves the final attempt rebased onto the fresh tip rather than clobbering).
REMOTE1_HAS_D2=$(cd "$REMOTE1" && git show "main:docs/remote_only2.txt" 2>/dev/null || echo "")
if [ "$REMOTE1_HAS_D2" = "second-remote-change" ]; then
    pass_test "Concurrent commit landed during backoff was preserved"
else
    fail_test "Concurrent backoff commit lost. Got: '$REMOTE1_HAS_D2'. Output: $OUTPUT1"
fi

# No unpushed backlog should remain.
UNPUSHED1=$(cd "$WORK1" && git rev-list --count "origin/main..HEAD" 2>/dev/null || echo "?")
if [ "$UNPUSHED1" = "0" ]; then
    pass_test "No unpushed commits remain after final-attempt recovery"
else
    fail_test "Expected 0 unpushed commits, got: $UNPUSHED1. Output: $OUTPUT1"
fi

# The status line must not be push-failed.
if echo "$OUTPUT1" | grep -q "reason=push-failed"; then
    fail_test "Run reported push-failed despite recoverable divergence. Output: $OUTPUT1"
else
    pass_test "Run did not report push-failed"
fi

# --------------------------------------------------------------------------
# Test 2 (defect 2): a rebase conflict on docs/repos.json must NOT silently
# drop this host's update. The update must be re-applied onto the fresh base
# and pushed so it reaches the remote.
# --------------------------------------------------------------------------
echo ""
echo "Test 2: rebase conflict on repos.json re-applies the update, not drops it..."
T2="${TMPDIR_BASE}/test2"
mkdir -p "$T2"
REMOTE2="${T2}/remote.git"
UPSTREAM2="${T2}/upstream"
WORK2="${T2}/work"

git init --bare --initial-branch=main "$REMOTE2" >/dev/null 2>&1
git clone --quiet "$REMOTE2" "$UPSTREAM2" >/dev/null 2>&1
mkdir -p "$UPSTREAM2/docs" "$UPSTREAM2/helpers"
echo '{"repos": []}' > "$UPSTREAM2/docs/repos.json"
cp "$REPOS_SCRIPT" "$UPSTREAM2/helpers/repos.sh"
cp "$GIT_RETRY_LIB" "$UPSTREAM2/helpers/git-retry.sh"
chmod +x "$UPSTREAM2/helpers/repos.sh" "$UPSTREAM2/helpers/git-retry.sh"
(
    cd "$UPSTREAM2"
    git add docs helpers >/dev/null 2>&1
    git commit -m "initial" --quiet >/dev/null 2>&1
    git push --quiet origin HEAD:main >/dev/null 2>&1
)

git clone --quiet "$REMOTE2" "$WORK2" >/dev/null 2>&1
(
    cd "$WORK2"
    git checkout -q main
    git config pull.ff only
    # Local-only commit that ALSO modifies repos.json — conflicts with the
    # remote change below on rebase.
    echo '{"repos": [{"name": "Stale", "last_commit_ts": 1}]}' > docs/repos.json
    git add docs/repos.json >/dev/null 2>&1
    git commit -m "stale local repos.json change" --quiet >/dev/null 2>&1
)

# Diverge the remote with a competing repos.json change.
(
    cd "$UPSTREAM2"
    git pull --quiet >/dev/null 2>&1 || true
    echo '{"repos": [{"name": "Other", "last_commit_ts": 2}]}' > docs/repos.json
    git add docs/repos.json >/dev/null 2>&1
    git commit -m "remote competing repos.json change" --quiet >/dev/null 2>&1
    git push --quiet origin HEAD:main >/dev/null 2>&1
)

OUTPUT2=$(cd "$WORK2" && GIT_PUSH_RETRY_DELAY_OVERRIDE=0 \
    ./helpers/repos.sh "ReappliedHost" --skip-rate-limit --project-root "$WORK2" 2>&1 || true)

(cd "$WORK2" && git fetch --quiet 2>/dev/null || true)

# The host's update must reach the remote — it must NOT be silently dropped.
REMOTE2_JSON=$(cd "$REMOTE2" && git show "main:docs/repos.json" 2>/dev/null || echo "")
if echo "$REMOTE2_JSON" | grep -q '"ReappliedHost"'; then
    pass_test "Host update re-applied and pushed after rebase conflict (not dropped)"
else
    fail_test "ReappliedHost missing on remote — update was dropped. json='$REMOTE2_JSON' output: $OUTPUT2"
fi

# The remote's competing commit must be preserved (we reset onto it, not over it).
REMOTE2_HAS_OTHER=$(echo "$REMOTE2_JSON" | grep -c '"Other"' || true)
if [ "$REMOTE2_HAS_OTHER" -ge 1 ]; then
    pass_test "Remote competing repos.json entry preserved through recovery"
else
    fail_test "Remote 'Other' entry lost. json='$REMOTE2_JSON'"
fi

# No unpushed backlog should remain.
UNPUSHED2=$(cd "$WORK2" && git rev-list --count "origin/main..HEAD" 2>/dev/null || echo "?")
if [ "$UNPUSHED2" = "0" ]; then
    pass_test "No unpushed backlog remains after conflict recovery"
else
    fail_test "Expected 0 unpushed commits, got: $UNPUSHED2. Output: $OUTPUT2"
fi

# --------------------------------------------------------------------------
# Test 3: grq_apply_jitter never shrinks below the base and returns the base
# unchanged when jitter is disabled (base 0 or ceiling 0) — keeps tests fast
# and de-syncs the fleet otherwise.
# --------------------------------------------------------------------------
echo ""
echo "Test 3: grq_apply_jitter bounds..."
# shellcheck disable=SC1090
. "$GIT_RETRY_LIB"

J0=$(grq_apply_jitter 0)
if [ "$J0" = "0" ]; then
    pass_test "grq_apply_jitter 0 returns 0 (instant retries preserved)"
else
    fail_test "grq_apply_jitter 0 returned '$J0'"
fi

J_DISABLED=$(GRQ_PUSH_JITTER_MAX=0 grq_apply_jitter 4)
if [ "$J_DISABLED" = "4" ]; then
    pass_test "grq_apply_jitter with ceiling 0 returns base unchanged"
else
    fail_test "grq_apply_jitter (ceiling 0) returned '$J_DISABLED'"
fi

JITTER_OK=true
for _ in 1 2 3 4 5 6 7 8; do
    JV=$(GRQ_PUSH_JITTER_MAX=3 grq_apply_jitter 4)
    if [ "$JV" -lt 4 ] || [ "$JV" -gt 7 ]; then
        JITTER_OK=false
        break
    fi
done
if [ "$JITTER_OK" = true ]; then
    pass_test "grq_apply_jitter stays within [base, base+ceiling]"
else
    fail_test "grq_apply_jitter produced out-of-range value '$JV'"
fi

# --------------------------------------------------------------------------
echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
