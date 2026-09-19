#!/bin/bash
# Compact the health repository's history to a single snapshot commit.
#
# Issue #211: every heartbeat commits into this repository, so the pack grew to
# 897 MB for a 32 MB working tree and every consumer paid for it on every
# clone. run.sh now publishes only a bounded log tail, which stops the growth;
# this script removes the history that was already accumulated.
#
# The rewrite keeps the *current* tree exactly — it is verified byte-for-byte
# before anything is moved — and discards every commit behind it. The published
# dashboard only ever reads the tip of the branch, so nothing a consumer uses is
# lost. History itself is discarded deliberately (Issue #211: "there is
# absolutely no need for the history").
#
# This is destructive and deliberately manual: dry run by default, --apply
# rewrites the local branch, --push force-pushes it. Every host re-clones
# afterwards (run.sh and the Vibe Coder hooks both treat their checkouts as
# disposable).
#
# Usage:
#   helpers/compact-history.sh [--repo <path>] [--branch <name>]
#                              [--remote <name>] [--message <text>]
#                              [--apply] [--push]

set -euo pipefail

REPO_PATH="."
BRANCH="Develop"
REMOTE="origin"
MESSAGE=""
APPLY=false
PUSH=false

usage() {
    cat <<'EOF'
Usage: helpers/compact-history.sh [OPTIONS]

  --repo <path>      Repository to compact (default: current directory)
  --branch <name>    Branch to compact (default: Develop)
  --remote <name>    Remote to push to (default: origin)
  --message <text>   Commit message for the snapshot commit
  --apply            Rewrite the local branch (default is a dry run)
  --push             Force-push the rewritten branch (implies --apply)
  --help             Show this help

Dry run by default: it reports the current size and what would change.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            REPO_PATH="${2:-}"
            [ -n "$REPO_PATH" ] || die "--repo requires a path"
            shift 2
            ;;
        --branch)
            BRANCH="${2:-}"
            [ -n "$BRANCH" ] || die "--branch requires a name"
            shift 2
            ;;
        --remote)
            REMOTE="${2:-}"
            [ -n "$REMOTE" ] || die "--remote requires a name"
            shift 2
            ;;
        --message)
            MESSAGE="${2:-}"
            [ -n "$MESSAGE" ] || die "--message requires text"
            shift 2
            ;;
        --apply)
            APPLY=true
            shift
            ;;
        --push)
            APPLY=true
            PUSH=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1"
            ;;
    esac
done

[ -d "$REPO_PATH" ] || die "repository path does not exist: ${REPO_PATH}"

git_repo() {
    git -C "$REPO_PATH" "$@"
}

git_repo rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not a git working tree: ${REPO_PATH}"

git_repo rev-parse --verify --quiet "refs/heads/${BRANCH}" >/dev/null \
    || die "branch not found: ${BRANCH}"

OLD_HEAD=$(git_repo rev-parse "refs/heads/${BRANCH}")
TREE=$(git_repo rev-parse "${BRANCH}^{tree}")
COMMIT_COUNT=$(git_repo rev-list --count "$BRANCH")
PACK_SIZE=$(git_repo count-objects -vH | sed -n 's/^size-pack: //p')

if [ -z "$MESSAGE" ]; then
    MESSAGE="Compact history: snapshot of ${BRANCH} at ${OLD_HEAD} (Issue #211)

Every heartbeat committed a full host log, so the pack grew without bound.
run.sh now publishes only a bounded log tail; this commit is the single
snapshot that replaces the history accumulated before that fix."
fi

echo "Repository:   ${REPO_PATH}"
echo "Branch:       ${BRANCH} (${OLD_HEAD})"
echo "Commits:      ${COMMIT_COUNT}"
echo "Pack size:    ${PACK_SIZE:-unknown}"
echo "Tree kept:    ${TREE}"
echo ""

if [ "$APPLY" = false ]; then
    echo "DRY RUN — nothing was changed."
    echo "Re-run with --apply to rewrite ${BRANCH} locally, or --push to publish it."
    exit 0
fi

# Refuse to rewrite on top of uncommitted work: the snapshot is taken from the
# committed tree, so anything uncommitted would be silently stranded.
if [ -n "$(git_repo status --porcelain)" ]; then
    die "working tree is not clean — commit or stash before compacting"
fi

NEW_HEAD=$(git_repo commit-tree "$TREE" -m "$MESSAGE")
[ -n "$NEW_HEAD" ] || die "failed to create the snapshot commit"

NEW_TREE=$(git_repo rev-parse "${NEW_HEAD}^{tree}")
[ "$NEW_TREE" = "$TREE" ] \
    || die "snapshot tree ${NEW_TREE} does not match ${TREE} — refusing to continue"

# Move the local branch first: the force-push is the irreversible step, so it
# goes last and only after the local rewrite has actually succeeded.
CURRENT_BRANCH=$(git_repo rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" = "$BRANCH" ]; then
    git_repo reset --hard --quiet "$NEW_HEAD" \
        || die "could not move ${BRANCH} to the snapshot commit — nothing was pushed"
else
    git_repo update-ref "refs/heads/${BRANCH}" "$NEW_HEAD" "$OLD_HEAD" \
        || die "could not move ${BRANCH} to the snapshot commit — nothing was pushed"
fi

# Drop the rewritten branch's reflog so its own old commits become unreachable.
# Scoped to this branch: expiring every reflog would destroy recovery points for
# refs this script was never asked to touch.
git_repo reflog expire --expire=now "refs/heads/${BRANCH}"
git_repo gc --prune=now --quiet

NEW_PACK_SIZE=$(git_repo count-objects -vH | sed -n 's/^size-pack: //p')
echo "Compacted ${BRANCH}: ${COMMIT_COUNT} commits -> 1 (${NEW_HEAD})"
echo "Pack size: ${PACK_SIZE:-unknown} -> ${NEW_PACK_SIZE:-unknown}"
echo "Note: the old commits stay reachable — and the pack stays large — while any"
echo "other ref still points at them (typically refs/remotes/${REMOTE}/${BRANCH})."
echo "The clone shrinks once the branch is pushed and re-fetched, or re-cloned."

if [ "$PUSH" = true ]; then
    # --force-with-lease against the SHA we read: if another host pushed while
    # we worked, the push is refused instead of discarding their commit.
    git_repo push --force-with-lease="${BRANCH}:${OLD_HEAD}" \
        "$REMOTE" "${NEW_HEAD}:refs/heads/${BRANCH}" \
        || die "force-push of the compacted branch was refused — the local branch is already at ${NEW_HEAD} (previous tip ${OLD_HEAD}); fetch and re-run"
    echo "Pushed compacted ${BRANCH} to ${REMOTE}"
    echo ""
    echo "Every host must re-clone: existing checkouts have the old history and"
    echo "their next pull --rebase will fail against the rewritten branch."
fi
