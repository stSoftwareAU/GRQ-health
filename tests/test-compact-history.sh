#!/bin/bash
# Test for Issue #211: helpers/compact-history.sh must collapse a branch's
# history to a single snapshot commit without changing the published tree, and
# must refuse to run when the inputs are not safe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPACT_SH="$SCRIPT_DIR/../helpers/compact-history.sh"

echo "Testing Issue #211: history compaction helper"
echo "============================================="
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

if [ ! -x "$COMPACT_SH" ]; then
    echo "  FAIL: helpers/compact-history.sh is missing or not executable"
    exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

export GIT_AUTHOR_NAME="Test"
export GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test"
export GIT_COMMITTER_EMAIL="test@example.com"

# Build a repo with a bare remote and three commits on a Develop branch.
make_repo() {
    local base="$1"
    local remote="${base}/remote.git"
    local work="${base}/work"

    git init --quiet --bare "$remote"
    git init --quiet -b Develop "$work"
    git -C "$work" remote add origin "$remote"

    local i
    for i in 1 2 3; do
        mkdir -p "${work}/docs"
        echo "log content revision ${i}" > "${work}/docs/node-test.log"
        echo "tree file ${i}" > "${work}/file-${i}.txt"
        git -C "$work" add -A
        git -C "$work" commit --quiet -m "commit ${i}"
    done
    git -C "$work" push --quiet -u origin Develop
    # The bare remote is created with the git default HEAD, so point it at the
    # branch under test; otherwise a clone of it checks nothing out.
    git -C "$remote" symbolic-ref HEAD refs/heads/Develop
    echo "$work"
}

# --- Test 1: dry run reports but changes nothing ---------------------------
echo "Test 1: dry run leaves history untouched..."
DRY_BASE="$WORK_DIR/dry"
mkdir -p "$DRY_BASE"
DRY_WORK=$(make_repo "$DRY_BASE")
BEFORE_COUNT=$(git -C "$DRY_WORK" rev-list --count Develop)

if DRY_OUTPUT=$("$COMPACT_SH" --repo "$DRY_WORK" --branch Develop 2>&1); then
    AFTER_COUNT=$(git -C "$DRY_WORK" rev-list --count Develop)
    if [ "$BEFORE_COUNT" = "$AFTER_COUNT" ] && [ "$AFTER_COUNT" = "3" ]; then
        pass_test "dry run left all ${AFTER_COUNT} commits in place"
    else
        fail_test "dry run changed history (${BEFORE_COUNT} -> ${AFTER_COUNT})"
    fi
    if echo "$DRY_OUTPUT" | grep -qi 'dry run'; then
        pass_test "dry run announces itself"
    else
        fail_test "dry run did not announce itself: ${DRY_OUTPUT}"
    fi
else
    fail_test "dry run returned non-zero"
fi

# --- Test 2: --apply collapses history and preserves the tree --------------
echo "Test 2: --apply collapses history to one commit with an identical tree..."
APPLY_BASE="$WORK_DIR/apply"
mkdir -p "$APPLY_BASE"
APPLY_WORK=$(make_repo "$APPLY_BASE")
TREE_BEFORE=$(git -C "$APPLY_WORK" rev-parse 'Develop^{tree}')

if "$COMPACT_SH" --repo "$APPLY_WORK" --branch Develop --apply >/dev/null 2>&1; then
    COUNT_AFTER=$(git -C "$APPLY_WORK" rev-list --count Develop)
    TREE_AFTER=$(git -C "$APPLY_WORK" rev-parse 'Develop^{tree}')
    if [ "$COUNT_AFTER" = "1" ]; then
        pass_test "history collapsed to a single commit"
    else
        fail_test "history has ${COUNT_AFTER} commits after --apply"
    fi
    if [ "$TREE_BEFORE" = "$TREE_AFTER" ]; then
        pass_test "published tree is byte-identical (${TREE_AFTER})"
    else
        fail_test "tree changed: ${TREE_BEFORE} -> ${TREE_AFTER}"
    fi
    if [ "$(cat "${APPLY_WORK}/docs/node-test.log")" = "log content revision 3" ]; then
        pass_test "working tree still holds the latest content"
    else
        fail_test "working tree content was lost"
    fi
    if git -C "$APPLY_WORK" status --porcelain | grep -q .; then
        fail_test "working tree is dirty after --apply"
    else
        pass_test "working tree is clean after --apply"
    fi
else
    fail_test "--apply returned non-zero"
fi

# --- Test 3: --push publishes the compacted branch -------------------------
echo "Test 3: --push publishes a single-commit branch to the remote..."
PUSH_BASE="$WORK_DIR/push"
mkdir -p "$PUSH_BASE"
PUSH_WORK=$(make_repo "$PUSH_BASE")
PUSH_TREE_BEFORE=$(git -C "$PUSH_WORK" rev-parse 'Develop^{tree}')

if "$COMPACT_SH" --repo "$PUSH_WORK" --branch Develop --push >/dev/null 2>&1; then
    REMOTE_COUNT=$(git -C "${PUSH_BASE}/remote.git" rev-list --count Develop)
    REMOTE_TREE=$(git -C "${PUSH_BASE}/remote.git" rev-parse 'Develop^{tree}')
    if [ "$REMOTE_COUNT" = "1" ]; then
        pass_test "remote branch has a single commit"
    else
        fail_test "remote branch has ${REMOTE_COUNT} commits"
    fi
    if [ "$REMOTE_TREE" = "$PUSH_TREE_BEFORE" ]; then
        pass_test "remote tree is unchanged by the rewrite"
    else
        fail_test "remote tree changed: ${PUSH_TREE_BEFORE} -> ${REMOTE_TREE}"
    fi

    # A fresh clone of the compacted remote must still have every file.
    git clone --quiet "${PUSH_BASE}/remote.git" "${PUSH_BASE}/fresh"
    if [ -f "${PUSH_BASE}/fresh/docs/node-test.log" ] && [ -f "${PUSH_BASE}/fresh/file-3.txt" ]; then
        pass_test "a fresh clone of the compacted remote has the full tree"
    else
        fail_test "a fresh clone is missing files"
    fi
else
    fail_test "--push returned non-zero"
fi

# --- Test 4: unsafe inputs fail loud ---------------------------------------
echo "Test 4: unsafe inputs fail loud..."

NOT_A_REPO="$WORK_DIR/not-a-repo"
mkdir -p "$NOT_A_REPO"
set +e
OUT=$("$COMPACT_SH" --repo "$NOT_A_REPO" --branch Develop 2>&1)
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -qi 'error'; then
    pass_test "a non-git directory is rejected"
else
    fail_test "a non-git directory was accepted (status ${STATUS})"
fi

MISSING_BASE="$WORK_DIR/missing-branch"
mkdir -p "$MISSING_BASE"
MISSING_WORK=$(make_repo "$MISSING_BASE")
set +e
OUT=$("$COMPACT_SH" --repo "$MISSING_WORK" --branch NoSuchBranch 2>&1)
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -qi 'error'; then
    pass_test "an unknown branch is rejected"
else
    fail_test "an unknown branch was accepted (status ${STATUS})"
fi

DIRTY_BASE="$WORK_DIR/dirty"
mkdir -p "$DIRTY_BASE"
DIRTY_WORK=$(make_repo "$DIRTY_BASE")
echo "uncommitted change" >> "${DIRTY_WORK}/file-1.txt"
set +e
OUT=$("$COMPACT_SH" --repo "$DIRTY_WORK" --branch Develop --apply 2>&1)
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -qi 'error'; then
    pass_test "a dirty working tree is rejected"
else
    fail_test "a dirty working tree was accepted (status ${STATUS})"
fi
if [ "$(git -C "$DIRTY_WORK" rev-list --count Develop)" = "3" ]; then
    pass_test "the rejected run left history intact"
else
    fail_test "the rejected run modified history"
fi

set +e
OUT=$("$COMPACT_SH" --repo "$DIRTY_WORK" --branch Develop --unknown-flag 2>&1)
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -qi 'error'; then
    pass_test "an unknown flag is rejected"
else
    fail_test "an unknown flag was accepted (status ${STATUS})"
fi

echo ""
echo "============================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
