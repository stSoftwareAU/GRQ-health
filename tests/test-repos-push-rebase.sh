#!/bin/bash
# Test for Issue stSoftwareAU/GRQ#1862: Harden push retry path in helpers/repos.sh
#
# Verifies that when `git push` fails because the remote has new commits
# (non-fast-forward), helpers/repos.sh:
#   1. Performs a fetch + rebase between push retries.
#   2. Successfully pushes the local commit on a subsequent retry.
#   3. Logs the actual `git push` stderr (not just a generic message) when all
#      retries are exhausted, plus `git status --porcelain=v2 --branch`.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_SCRIPT="$SCRIPT_DIR/../helpers/repos.sh"

echo "Testing Issue #1862: Push retry rebase recovery in repos.sh"
echo "==========================================================="
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

# Create a temp area
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Configure git identity for non-interactive test commits
export GIT_AUTHOR_NAME="Test"
export GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test"
export GIT_COMMITTER_EMAIL="test@example.com"

# Build a working clone whose local branch genuinely diverges from origin:
#   * remote has one extra commit that the work clone has not seen
#   * work clone has one local-only commit (an unrelated file) that has not
#     been pushed
# This guarantees `git pull --ff-only` will fail and `git push` is non-FF.
setup_diverged_clone() {
    local base="$1"
    local remote_dir="${base}/remote.git"
    local upstream_dir="${base}/upstream"
    local work_dir="${base}/work"

    git init --bare --initial-branch=main "$remote_dir" >/dev/null 2>&1

    # Seed the remote via an upstream clone
    git clone --quiet "$remote_dir" "$upstream_dir" >/dev/null 2>&1
    mkdir -p "$upstream_dir/docs" "$upstream_dir/helpers"
    echo '{"repos": []}' > "$upstream_dir/docs/repos.json"
    cp "$REPOS_SCRIPT" "$upstream_dir/helpers/repos.sh"
    chmod +x "$upstream_dir/helpers/repos.sh"
    (
        cd "$upstream_dir"
        git add docs helpers >/dev/null 2>&1
        git commit -m "initial" --quiet >/dev/null 2>&1
        git push --quiet origin HEAD:main >/dev/null 2>&1
    )

    # Create the working clone (will run repos.sh)
    git clone --quiet "$remote_dir" "$work_dir" >/dev/null 2>&1
    (
        cd "$work_dir"
        git checkout -q main 2>/dev/null || git checkout -q -b main
        # Force pull to refuse on divergence — emulates the snowball case
        # where pull cannot transparently fast-forward.
        git config pull.ff only
        # Add a local-only commit (unpushed) that touches a different file
        # from the remote-only commit, so rebase will not conflict.
        echo "local-only" > docs/local_only.txt
        git add docs/local_only.txt >/dev/null 2>&1
        git commit -m "local-only commit" --quiet >/dev/null 2>&1
    )

    # Diverge the remote with a different commit
    (
        cd "$upstream_dir"
        git pull --quiet >/dev/null 2>&1 || true
        echo "remote-change" > docs/remote_only.txt
        git add docs/remote_only.txt >/dev/null 2>&1
        git commit -m "remote-only commit" --quiet >/dev/null 2>&1
        git push --quiet origin HEAD:main >/dev/null 2>&1
    )

    echo "$work_dir"
}

# --------------------------------------------------------------------------
# Test 1: Non-fast-forward push recovers via rebase between retries
# --------------------------------------------------------------------------
echo "Test 1: Non-fast-forward push recovers via fetch + rebase..."
TEST1_BASE="${TMPDIR_BASE}/test1"
mkdir -p "$TEST1_BASE"
WORK_DIR=$(setup_diverged_clone "$TEST1_BASE")

# Sanity check: confirm we have the expected pre-state.
PRE_LOCAL_AHEAD=$(cd "$WORK_DIR" && git rev-list --count "origin/main..HEAD" 2>/dev/null || echo "?")
PRE_REMOTE_AHEAD=$(cd "$WORK_DIR" && git fetch --quiet 2>/dev/null; git rev-list --count "HEAD..origin/main" 2>/dev/null || echo "?")
if [ "$PRE_LOCAL_AHEAD" = "1" ] && [ "$PRE_REMOTE_AHEAD" = "1" ]; then
    pass_test "Pre-state: branches diverged (1 local, 1 remote)"
else
    fail_test "Pre-state wrong: local ahead=$PRE_LOCAL_AHEAD, remote ahead=$PRE_REMOTE_AHEAD"
fi

# Run the script with retries sped up via env override
OUTPUT=$(cd "$WORK_DIR" && GIT_PUSH_RETRY_DELAY_OVERRIDE=0 \
    ./helpers/repos.sh "TestRepo" --skip-rate-limit --project-root "$WORK_DIR" 2>&1 || true)

# After running, the remote should have all three pieces of work:
#   * the original "remote-only" commit (preserved)
#   * the local-only commit (rebased on top)
#   * the repos.json update from this run
REMOTE_HEAD_AFTER=$(cd "${TEST1_BASE}/remote.git" && git rev-parse main 2>/dev/null || echo "")
WORK_HEAD_AFTER=$(cd "$WORK_DIR" && git rev-parse HEAD 2>/dev/null || echo "")

if [ -n "$REMOTE_HEAD_AFTER" ] && [ "$REMOTE_HEAD_AFTER" = "$WORK_HEAD_AFTER" ]; then
    pass_test "Local HEAD matches remote HEAD after non-fast-forward recovery"
else
    fail_test "Expected local and remote HEADs to match. local=$WORK_HEAD_AFTER remote=$REMOTE_HEAD_AFTER. Output: $OUTPUT"
fi

# repos.json on the remote should contain TestRepo entry (the local commit
# survived the rebase and was pushed).
REMOTE_REPOS_JSON=$(cd "${TEST1_BASE}/remote.git" && git show "main:docs/repos.json" 2>/dev/null || echo "")
if echo "$REMOTE_REPOS_JSON" | grep -q '"TestRepo"'; then
    pass_test "TestRepo entry is present on remote (push succeeded after rebase)"
else
    fail_test "TestRepo not found on remote. repos.json contents: $REMOTE_REPOS_JSON"
fi

# remote_only.txt from the divergent commit must still exist (rebase didn't
# clobber the remote work).
REMOTE_HAS_REMOTE_ONLY=$(cd "${TEST1_BASE}/remote.git" && git show "main:docs/remote_only.txt" 2>/dev/null || echo "")
if [ "$REMOTE_HAS_REMOTE_ONLY" = "remote-change" ]; then
    pass_test "Remote-only commit was preserved through rebase"
else
    fail_test "Remote-only commit was lost. Got: '$REMOTE_HAS_REMOTE_ONLY'"
fi

# local-only commit's content should also be on remote (rebased forward).
REMOTE_HAS_LOCAL_ONLY=$(cd "${TEST1_BASE}/remote.git" && git show "main:docs/local_only.txt" 2>/dev/null || echo "")
if [ "$REMOTE_HAS_LOCAL_ONLY" = "local-only" ]; then
    pass_test "Local-only commit was rebased onto remote and pushed"
else
    fail_test "Local-only commit missing on remote. Got: '$REMOTE_HAS_LOCAL_ONLY'"
fi

# There should be no unpushed commits left in the working clone.
UNPUSHED=$(cd "$WORK_DIR" && git rev-list --count "origin/main..HEAD" 2>/dev/null || echo "?")
if [ "$UNPUSHED" = "0" ]; then
    pass_test "No unpushed commits remain in the working clone"
else
    fail_test "Expected 0 unpushed commits, got: $UNPUSHED"
fi

# Output should mention the rebase recovery, not just generic retry text.
if echo "$OUTPUT" | grep -qi "rebas"; then
    pass_test "Output mentions rebase recovery between retries"
else
    fail_test "Expected rebase mention in output. Got: $OUTPUT"
fi

# --------------------------------------------------------------------------
# Test 2: When push truly fails, stderr is surfaced in the output
# --------------------------------------------------------------------------
echo ""
echo "Test 2: Final push failure surfaces git stderr and porcelain status..."
TEST2_BASE="${TMPDIR_BASE}/test2"
mkdir -p "$TEST2_BASE"
WORK_DIR2=$(setup_diverged_clone "$TEST2_BASE")

# Break the remote so push will always fail.
(
    cd "$WORK_DIR2"
    git remote set-url origin "${TEST2_BASE}/no-such-remote.git"
)

OUTPUT2=$(cd "$WORK_DIR2" && GIT_PUSH_RETRY_DELAY_OVERRIDE=0 \
    ./helpers/repos.sh "TestRepo2" --skip-rate-limit --project-root "$WORK_DIR2" 2>&1 || true)

# When all retries fail, the script must surface the actual git stderr
# (e.g. "fatal", "does not appear to be a git repository", etc.) rather
# than only the generic "git push failed" line.
if echo "$OUTPUT2" | grep -Ei "fatal:|does not appear|repository.*not found|no-such-remote|Could not read|unable to access" >/dev/null; then
    pass_test "Final failure output contains actual git stderr"
else
    fail_test "Expected git stderr in failure output. Got: $OUTPUT2"
fi

# Should also include branch info from `git status --porcelain=v2 --branch`
if echo "$OUTPUT2" | grep -E "^# branch\.|branch\.head|branch\.oid" >/dev/null; then
    pass_test "Final failure output includes git status --porcelain branch info"
else
    fail_test "Expected porcelain branch info in output. Got: $OUTPUT2"
fi

# --------------------------------------------------------------------------
# Test 3: Rebase conflict on repos.json is recovered by abort + reset
# --------------------------------------------------------------------------
echo ""
echo "Test 3: Rebase conflict on repos.json is discarded safely..."
TEST3_BASE="${TMPDIR_BASE}/test3"
mkdir -p "$TEST3_BASE"
TEST3_REMOTE="${TEST3_BASE}/remote.git"
TEST3_UPSTREAM="${TEST3_BASE}/upstream"
TEST3_WORK="${TEST3_BASE}/work"

git init --bare --initial-branch=main "$TEST3_REMOTE" >/dev/null 2>&1
git clone --quiet "$TEST3_REMOTE" "$TEST3_UPSTREAM" >/dev/null 2>&1
mkdir -p "$TEST3_UPSTREAM/docs" "$TEST3_UPSTREAM/helpers"
echo '{"repos": []}' > "$TEST3_UPSTREAM/docs/repos.json"
cp "$REPOS_SCRIPT" "$TEST3_UPSTREAM/helpers/repos.sh"
chmod +x "$TEST3_UPSTREAM/helpers/repos.sh"
(
    cd "$TEST3_UPSTREAM"
    git add docs helpers >/dev/null 2>&1
    git commit -m "initial" --quiet >/dev/null 2>&1
    git push --quiet origin HEAD:main >/dev/null 2>&1
)

git clone --quiet "$TEST3_REMOTE" "$TEST3_WORK" >/dev/null 2>&1
(
    cd "$TEST3_WORK"
    git checkout -q main
    git config pull.ff only
    # Local-only commit that ALSO modifies repos.json — will conflict with
    # the upcoming remote commit.
    echo '{"repos": [{"name": "Stale", "last_commit_ts": 1}]}' > docs/repos.json
    git add docs/repos.json >/dev/null 2>&1
    git commit -m "stale local repos.json change" --quiet >/dev/null 2>&1
)

# Diverge the remote with a competing repos.json change
(
    cd "$TEST3_UPSTREAM"
    git pull --quiet >/dev/null 2>&1 || true
    echo '{"repos": [{"name": "Other", "last_commit_ts": 2}]}' > docs/repos.json
    git add docs/repos.json >/dev/null 2>&1
    git commit -m "remote competing repos.json change" --quiet >/dev/null 2>&1
    git push --quiet origin HEAD:main >/dev/null 2>&1
)

OUTPUT3=$(cd "$TEST3_WORK" && GIT_PUSH_RETRY_DELAY_OVERRIDE=0 \
    ./helpers/repos.sh "TestRepo3" --skip-rate-limit --project-root "$TEST3_WORK" 2>&1 || true)

# After the conflict-and-discard recovery, the working clone must NOT have
# a backlog of unpushed commits relative to remote main.
(cd "$TEST3_WORK" && git fetch --quiet 2>/dev/null || true)
UNPUSHED3=$(cd "$TEST3_WORK" && git rev-list --count "origin/main..HEAD" 2>/dev/null || echo "?")

if [ "$UNPUSHED3" = "0" ]; then
    pass_test "After conflict + discard, no unpushed backlog remains"
else
    fail_test "Expected 0 unpushed commits after conflict recovery, got: $UNPUSHED3. Output: $OUTPUT3"
fi

# The script should mention discarding/resetting in its output so operators
# can see what happened.
if echo "$OUTPUT3" | grep -Ei "discard|reset" >/dev/null; then
    pass_test "Output mentions discard/reset on rebase conflict"
else
    fail_test "Expected discard/reset mention in output. Got: $OUTPUT3"
fi

# --------------------------------------------------------------------------
echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
