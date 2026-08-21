#!/bin/bash
# Test for Issue stSoftwareAU/GRQ#4237: the health check-in must never run on
# from an unresolved git state.
#
# Step 1 of helpers/repos.sh pulls before staging docs/repos.json. The pull runs
# with a DIRTY tree — repos.json was rewritten moments earlier — so a plain
# `git pull` refuses ("Your local changes … would be overwritten") or, once the
# branches diverge, exits with "Need to specify how to reconcile divergent
# branches". The script then printed
#   "Warning: Could not resolve git state, will attempt to update repos.json anyway"
# and carried on committing and pushing from that unresolved state.
#
# Verifies that helpers/repos.sh:
#   1. Pulls with --rebase --autostash, so the dirty repos.json + a diverged
#      remote resolve cleanly and the update is pushed.
#   2. Aborts loudly (non-zero exit, status=failed reason=git-state-unresolved,
#      no commit) when the git state genuinely cannot be resolved.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_SCRIPT="$SCRIPT_DIR/../helpers/repos.sh"

echo "Testing Issue GRQ#4237: unresolved git state aborts the health check-in"
echo "======================================================================="
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

# A work clone whose branch has diverged from origin, exactly as it does when a
# peer host records its own health update between our fetch and our push.
setup_diverged_clone() {
    local base="$1"
    local remote_dir="${base}/remote.git"
    local upstream_dir="${base}/upstream"
    local work_dir="${base}/work"

    git init --bare --initial-branch=main "$remote_dir" >/dev/null 2>&1

    git clone --quiet "$remote_dir" "$upstream_dir" >/dev/null 2>&1
    mkdir -p "$upstream_dir/docs" "$upstream_dir/helpers"
    echo '{"repos": []}' > "$upstream_dir/docs/repos.json"
    cp "$REPOS_SCRIPT" "$upstream_dir/helpers/repos.sh"
    cp "$SCRIPT_DIR/../helpers/git-retry.sh" "$upstream_dir/helpers/git-retry.sh"
    chmod +x "$upstream_dir/helpers/repos.sh" "$upstream_dir/helpers/git-retry.sh"
    (
        cd "$upstream_dir"
        git add docs helpers >/dev/null 2>&1
        git commit -m "initial" --quiet >/dev/null 2>&1
        git push --quiet origin HEAD:main >/dev/null 2>&1
    )

    git clone --quiet "$remote_dir" "$work_dir" >/dev/null 2>&1
    (
        cd "$work_dir"
        git checkout -q main 2>/dev/null || git checkout -q -b main
        echo "local-only" > docs/local_only.txt
        git add docs/local_only.txt >/dev/null 2>&1
        git commit -m "local-only commit" --quiet >/dev/null 2>&1
    )

    # The peer's commit lands after our clone last fetched.
    (
        cd "$upstream_dir"
        git pull --quiet >/dev/null 2>&1 || true
        echo "peer-change" > docs/peer_only.txt
        git add docs/peer_only.txt >/dev/null 2>&1
        git commit -m "peer-only commit" --quiet >/dev/null 2>&1
        git push --quiet origin HEAD:main >/dev/null 2>&1
    )

    echo "$work_dir"
}

# --------------------------------------------------------------------------
# Test 1: dirty repos.json + diverged remote resolves and pushes
# --------------------------------------------------------------------------
echo "Test 1: diverged remote with a dirty repos.json pulls cleanly..."
TEST1_BASE="${TMPDIR_BASE}/test1"
mkdir -p "$TEST1_BASE"
WORK_DIR=$(setup_diverged_clone "$TEST1_BASE")

set +e
OUTPUT=$(cd "$WORK_DIR" && GIT_PUSH_RETRY_DELAY_OVERRIDE=0 \
    ./helpers/repos.sh "PullRepo" --skip-rate-limit --project-root "$WORK_DIR" 2>&1)
STATUS=$?
set -e

if [ "$STATUS" -eq 0 ]; then
    pass_test "repos.sh exits 0 when the pull resolves"
else
    fail_test "Expected exit 0, got ${STATUS}. Output: $OUTPUT"
fi

if ! echo "$OUTPUT" | grep -q "will attempt to update repos.json anyway"; then
    pass_test "No 'update repos.json anyway' warning — the pull resolved"
else
    fail_test "Still proceeding from an unresolved state. Output: $OUTPUT"
fi

REMOTE_REPOS_JSON=$(cd "${TEST1_BASE}/remote.git" && git show "main:docs/repos.json" 2>/dev/null || echo "")
if echo "$REMOTE_REPOS_JSON" | grep -q '"PullRepo"'; then
    pass_test "This host's health update reached the remote"
else
    fail_test "PullRepo missing on remote. repos.json: $REMOTE_REPOS_JSON"
fi

REMOTE_PEER=$(cd "${TEST1_BASE}/remote.git" && git show "main:docs/peer_only.txt" 2>/dev/null || echo "")
if [ "$REMOTE_PEER" = "peer-change" ]; then
    pass_test "The peer's commit survived the rebase"
else
    fail_test "Peer commit lost. Got: '$REMOTE_PEER'"
fi

REMOTE_LOCAL=$(cd "${TEST1_BASE}/remote.git" && git show "main:docs/local_only.txt" 2>/dev/null || echo "")
if [ "$REMOTE_LOCAL" = "local-only" ]; then
    pass_test "The unpushed local commit was rebased forward and pushed"
else
    fail_test "Local commit lost. Got: '$REMOTE_LOCAL'"
fi

# --------------------------------------------------------------------------
# Test 2: an unresolvable git state aborts instead of committing anyway
# --------------------------------------------------------------------------
echo ""
echo "Test 2: an unresolvable git state aborts the check-in..."
TEST2_BASE="${TMPDIR_BASE}/test2"
mkdir -p "$TEST2_BASE"
WORK_DIR2=$(setup_diverged_clone "$TEST2_BASE")

# Point origin at nothing: the pull cannot be resolved by any recovery step.
(
    cd "$WORK_DIR2"
    git remote set-url origin "${TEST2_BASE}/no-such-remote.git"
)
set +e
OUTPUT2=$(cd "$WORK_DIR2" && GIT_PUSH_RETRY_DELAY_OVERRIDE=0 \
    ./helpers/repos.sh "AbortRepo" --skip-rate-limit --project-root "$WORK_DIR2" 2>&1)
STATUS2=$?
set -e

if [ "$STATUS2" -ne 0 ]; then
    pass_test "Unresolvable git state exits non-zero"
else
    fail_test "Expected a non-zero exit. Output: $OUTPUT2"
fi

if echo "$OUTPUT2" | grep -q "reason=git-state-unresolved"; then
    pass_test "Status line reports reason=git-state-unresolved"
else
    fail_test "Expected reason=git-state-unresolved in the status line. Output: $OUTPUT2"
fi

if ! echo "$OUTPUT2" | grep -q "will attempt to update repos.json anyway"; then
    pass_test "The check-in aborts instead of updating repos.json anyway"
else
    fail_test "Still proceeding from an unresolved state. Output: $OUTPUT2"
fi

COMMITTED=$(cd "$WORK_DIR2" && git log --all --pretty=%H -S'AbortRepo' 2>/dev/null | wc -l | tr -d ' ')
if [ "$COMMITTED" = "0" ]; then
    pass_test "No commit was created from the unresolved state"
else
    fail_test "A commit carrying the health update was created despite the unresolved state"
fi

DIRTY=$(cd "$WORK_DIR2" && git status --porcelain)
if [ -z "$DIRTY" ]; then
    pass_test "The clone is left clean for the next run"
else
    fail_test "Working tree dirty after the abort: $DIRTY"
fi

echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
