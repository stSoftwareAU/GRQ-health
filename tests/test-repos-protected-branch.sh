#!/bin/bash
# Test for Issue #143: a protected-branch (GH006) push rejection is a
# non-retryable outcome.
#
# A write-only fleet account cannot bypass the required status checks on the
# protected branch, so every one of the 5 push attempts is declined
# identically — burning ~80s of retry budget every cycle. The fix detects the
# GH006 / "protected branch hook declined" / "required status checks are
# expected" signature and:
#   1. stops after the FIRST push attempt (no retry), and
#   2. reports a distinct status line reason=protected-branch instead of the
#      generic push-failed.
#
# Two layers are covered:
#   Part A — grq_is_protected_branch_error() classifies stderr correctly
#            (happy path, non-matching error path, edge cases).
#   Part B — helpers/repos.sh fails fast with reason=protected-branch and does
#            NOT exhaust the retry budget when the remote declines the push.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_SCRIPT="$SCRIPT_DIR/../helpers/repos.sh"
GIT_RETRY_LIB="$SCRIPT_DIR/../helpers/git-retry.sh"

# shellcheck disable=SC1090
. "$GIT_RETRY_LIB"

echo "Testing Issue #143: protected-branch (GH006) push is non-retryable"
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

export GIT_AUTHOR_NAME="Test"
export GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test"
export GIT_COMMITTER_EMAIL="test@example.com"

# --------------------------------------------------------------------------
# Part A: grq_is_protected_branch_error classification
# --------------------------------------------------------------------------
echo "Part A: grq_is_protected_branch_error classification..."

# Happy path — the exact GH006 signature from the live reproduction.
GH006_STDERR='remote: error: GH006: Protected branch update failed for refs/heads/Develop.
remote: - 4 of 4 required status checks are expected.
 ! [remote rejected]     Develop -> Develop (protected branch hook declined)
error: failed to push some refs'

if echo "$GH006_STDERR" | grq_is_protected_branch_error; then
    pass_test "Detects the GH006 protected-branch rejection"
else
    fail_test "Failed to detect GH006 protected-branch rejection"
fi

# Detect the "protected branch hook declined" phrasing on its own.
if echo "protected branch hook declined" | grq_is_protected_branch_error; then
    pass_test "Detects 'protected branch hook declined'"
else
    fail_test "Failed to detect 'protected branch hook declined'"
fi

# Detect the required-status-checks phrasing on its own.
if echo "4 of 4 required status checks are expected" | grq_is_protected_branch_error; then
    pass_test "Detects 'required status checks are expected'"
else
    fail_test "Failed to detect 'required status checks are expected'"
fi

# Error path — a non-fast-forward rejection is a DIFFERENT, retryable outcome
# and must NOT be misclassified as a protected-branch rejection.
NFF_STDERR=' ! [rejected]        Develop -> Develop (fetch first)
error: failed to push some refs to origin
hint: Updates were rejected because the remote contains work that you do not have'
if echo "$NFF_STDERR" | grq_is_protected_branch_error; then
    fail_test "Non-fast-forward rejection wrongly classified as protected-branch"
else
    pass_test "Non-fast-forward rejection is NOT classified as protected-branch"
fi

# Edge case — empty stderr must not match.
if echo "" | grq_is_protected_branch_error; then
    fail_test "Empty stderr wrongly classified as protected-branch"
else
    pass_test "Empty stderr is not classified as protected-branch"
fi

# Edge case — a plain rate-limit message must not match.
if echo "You have exceeded a secondary rate limit" | grq_is_protected_branch_error; then
    fail_test "Rate-limit message wrongly classified as protected-branch"
else
    pass_test "Rate-limit message is not classified as protected-branch"
fi

# --------------------------------------------------------------------------
# Part B: repos.sh fails fast (no retries) with reason=protected-branch
# --------------------------------------------------------------------------
echo ""
echo "Part B: repos.sh fails fast with reason=protected-branch..."

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

REMOTE="${TMPDIR_BASE}/remote.git"
UPSTREAM="${TMPDIR_BASE}/upstream"
WORK="${TMPDIR_BASE}/work"

git init --bare --initial-branch=main "$REMOTE" >/dev/null 2>&1
git clone --quiet "$REMOTE" "$UPSTREAM" >/dev/null 2>&1
mkdir -p "$UPSTREAM/docs" "$UPSTREAM/helpers"
echo '{"repos": []}' > "$UPSTREAM/docs/repos.json"
cp "$REPOS_SCRIPT" "$UPSTREAM/helpers/repos.sh"
cp "$GIT_RETRY_LIB" "$UPSTREAM/helpers/git-retry.sh"
chmod +x "$UPSTREAM/helpers/repos.sh" "$UPSTREAM/helpers/git-retry.sh"
(
    cd "$UPSTREAM"
    git add docs helpers >/dev/null 2>&1
    git commit -m "initial" --quiet >/dev/null 2>&1
    git push --quiet origin HEAD:main >/dev/null 2>&1
)

git clone --quiet "$REMOTE" "$WORK" >/dev/null 2>&1
(
    cd "$WORK"
    git checkout -q main
    git config pull.ff only
)

# Mock git shim: every `git push` is declined with the GH006 signature and the
# invocation is counted. All other git subcommands delegate to the real git so
# staging, commit, fetch and rebase behave normally.
SHIM_DIR="${TMPDIR_BASE}/shim"
mkdir -p "$SHIM_DIR"
PUSH_COUNT_FILE="${TMPDIR_BASE}/push_count"
echo "0" > "$PUSH_COUNT_FILE"
REAL_GIT=$(command -v git)

cat > "${SHIM_DIR}/git" <<MOCKEOF
#!/bin/bash
PUSH_COUNT_FILE="${PUSH_COUNT_FILE}"
REAL_GIT="${REAL_GIT}"
# Find the git subcommand, skipping any leading global -c/-C options.
sub=""
for a in "\$@"; do
    case "\$a" in
        -*) continue ;;
        *) sub="\$a"; break ;;
    esac
done
if [ "\$sub" = "push" ]; then
    count=\$(cat "\$PUSH_COUNT_FILE")
    count=\$((count + 1))
    echo "\$count" > "\$PUSH_COUNT_FILE"
    {
        echo "remote: error: GH006: Protected branch update failed for refs/heads/main."
        echo "remote: - 4 of 4 required status checks are expected."
        echo " ! [remote rejected]     main -> main (protected branch hook declined)"
        echo "error: failed to push some refs to origin"
    } >&2
    exit 1
fi
exec "\$REAL_GIT" "\$@"
MOCKEOF
chmod +x "${SHIM_DIR}/git"

set +e
OUTPUT=$(cd "$WORK" && \
    PATH="${SHIM_DIR}:$PATH" \
    GIT_PUSH_RETRY_DELAY_OVERRIDE=0 \
    ./helpers/repos.sh "GRQ-23" --skip-rate-limit --project-root "$WORK" 2>&1)
REPOS_EXIT=$?
set -e

FINAL_PUSH_COUNT=$(cat "$PUSH_COUNT_FILE")

# Only ONE push attempt should have been made — the GH006 rejection is
# non-retryable, so the loop must stop immediately.
if [ "$FINAL_PUSH_COUNT" -eq 1 ]; then
    pass_test "Protected-branch rejection stopped after a single push attempt (no retry)"
else
    fail_test "Expected exactly 1 push attempt, got: $FINAL_PUSH_COUNT. Output: $OUTPUT"
fi

# The status line must carry the distinct reason=protected-branch.
if echo "$OUTPUT" | grep -q "reason=protected-branch"; then
    pass_test "Status line reports reason=protected-branch"
else
    fail_test "Expected reason=protected-branch in status line. Output: $OUTPUT"
fi

# It must NOT masquerade as the generic push-failed reason.
if echo "$OUTPUT" | grep -q "reason=push-failed"; then
    fail_test "Protected-branch rejection wrongly reported as reason=push-failed. Output: $OUTPUT"
else
    pass_test "Did not report the generic reason=push-failed"
fi

# The run must still exit non-zero so the failure is observable.
if [ "$REPOS_EXIT" -ne 0 ]; then
    pass_test "repos.sh exits non-zero on a protected-branch rejection"
else
    fail_test "Expected non-zero exit, got: $REPOS_EXIT. Output: $OUTPUT"
fi

# Summary
echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
