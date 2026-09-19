#!/bin/bash
# Test for Issue #211: the host-local recovery artefacts written around every
# index.json update (the .bak backup and any .corrupted.<ts> copy) must live
# outside the published docs/ tree and must never be committed. Committing the
# backup added a second full-size JSON blob to every heartbeat, and every
# consumer paid for it on every clone.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_SH="$REPO_ROOT/run.sh"

echo "Testing Issue #211: recovery artefacts stay out of the published tree"
echo "====================================================================="
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

# Load the shipped configuration and implementation from run.sh (same pattern
# as the other run.sh function tests) so the test exercises real code.
eval "$(grep '^JSON_BACKUP_DIR=' "$RUN_SH" || true)"
eval "$(grep '^JSON_BACKUP_FILE=' "$RUN_SH" || true)"
eval "$(sed -n '/^backup_health_json()/,/^}/p' "$RUN_SH")"

if ! type backup_health_json >/dev/null 2>&1; then
    echo "  FAIL: backup_health_json is not defined in run.sh"
    exit 1
fi

# --- Test 1: the backup is written where it is told ------------------------
echo "Test 1: the recovery backup is written and matches the source..."
SRC="$WORK_DIR/index.json"
DEST="$WORK_DIR/local-state/index.json.bak"
printf '{"GRQ-1":{"heart_beat_ts":1}}\n' > "$SRC"

if backup_health_json "$SRC" "$DEST" >/dev/null; then
    if [ -f "$DEST" ] && cmp -s "$SRC" "$DEST"; then
        pass_test "backup written byte-for-byte (directory created on demand)"
    else
        fail_test "backup missing or does not match the source"
    fi
else
    fail_test "backup_health_json returned non-zero for a valid source"
fi

# --- Test 2: a missing source fails loud -----------------------------------
echo "Test 2: a missing source fails loud rather than reporting success..."
if backup_health_json "$WORK_DIR/does-not-exist.json" "$WORK_DIR/out.bak" >/dev/null 2>&1; then
    fail_test "backup_health_json returned 0 for a missing source"
else
    pass_test "missing source rejected with a non-zero exit"
fi

# --- Test 3: the configured backup path is outside docs/ -------------------
echo "Test 3: the shipped backup path is outside the published docs/ tree..."
if [ -z "${JSON_BACKUP_FILE:-}" ]; then
    fail_test "run.sh does not define JSON_BACKUP_FILE"
elif [ "${JSON_BACKUP_FILE#docs/}" != "$JSON_BACKUP_FILE" ]; then
    fail_test "backup path is inside docs/: ${JSON_BACKUP_FILE}"
else
    pass_test "backup path is outside docs/: ${JSON_BACKUP_FILE}"
fi

# --- Test 4: the ignore rules refuse to stage the artefacts ----------------
# The legacy docs/index.json.bak committed before this change is deliberately
# left tracked: every host still on the older run.sh rewrites it, so deleting
# it here would conflict with Develop within minutes. It stops changing once
# the fleet picks up this run.sh. What must hold now is that the artefacts can
# never be staged as *new* files again.
echo "Test 4: git refuses to stage the recovery artefacts..."
SCRATCH="$WORK_DIR/scratch"
mkdir -p "$SCRATCH/docs"
cp "$REPO_ROOT/.gitignore" "$SCRATCH/.gitignore"
git -C "$SCRATCH" init --quiet
printf '{}\n' > "$SCRATCH/docs/index.json"
printf '{}\n' > "$SCRATCH/docs/index.json.bak"
printf '{}\n' > "$SCRATCH/docs/index.json.corrupted.1782986793"
# Staging files an interrupted heartbeat can strand in the published tree
mkdir -p "$SCRATCH/docs/GRQ-1"
printf 'log\n' > "$SCRATCH/docs/GRQ-1/node-u.log"
printf 'log\n' > "$SCRATCH/docs/GRQ-1/.node-u.log.tmp.4242"
printf 'log\n' > "$SCRATCH/docs/GRQ-1/node-u.log.tmp.4242"
mkdir -p "$SCRATCH/${JSON_BACKUP_DIR:-.grq-health}"
printf '{}\n' > "$SCRATCH/${JSON_BACKUP_DIR:-.grq-health}/index.json.bak"
git -C "$SCRATCH" add -A >/dev/null 2>&1
STAGED=$(git -C "$SCRATCH" diff --cached --name-only)

if printf '%s\n' "$STAGED" | grep -q '^docs/index.json$'; then
    pass_test "the published docs/index.json is still staged"
else
    fail_test "docs/index.json was not staged (ignore rules are too broad)"
fi

if printf '%s\n' "$STAGED" | grep -qE 'index\.json\.(bak|corrupted)'; then
    fail_test "a recovery artefact was staged: $(printf '%s\n' "$STAGED" | grep -E 'index\.json\.(bak|corrupted)' | tr '\n' ' ')"
else
    pass_test "no .bak or .corrupted artefact was staged"
fi

if printf '%s\n' "$STAGED" | grep -q '^docs/GRQ-1/node-u.log$'; then
    pass_test "the published log file is still staged"
else
    fail_test "the published log file was not staged (ignore rules are too broad)"
fi

if printf '%s\n' "$STAGED" | grep -q 'tmp\.4242'; then
    fail_test "a stranded staging file was staged: $(printf '%s\n' "$STAGED" | grep 'tmp\.4242' | tr '\n' ' ')"
else
    pass_test "no stranded log staging file was staged"
fi

# --- Test 5: the backup directory is ignored in this repository ------------
echo "Test 5: the backup directory is ignored in this repository..."
if git -C "$REPO_ROOT" check-ignore -q "${JSON_BACKUP_DIR:-.grq-health}/index.json.bak"; then
    pass_test "${JSON_BACKUP_DIR:-.grq-health}/ is ignored"
else
    fail_test "${JSON_BACKUP_DIR:-.grq-health}/ is not ignored — heartbeats would commit it"
fi

# --- Test 6: a backup directory inside docs/ is refused --------------------
# A backup directory under docs/ would be staged by the heartbeat's
# `git add docs/`, which is the bug this change removes. run.sh must refuse it
# before doing any work rather than quietly re-creating the bug.
echo "Test 6: a GRQ_BACKUP_DIR inside docs/ is refused..."
REJECT_OUTPUT=$(cd "$REPO_ROOT" && GRQ_BACKUP_DIR="docs/state" bash run.sh --no-git 2>&1 </dev/null || true)
REJECT_STATUS=$(cd "$REPO_ROOT" && GRQ_BACKUP_DIR="docs/state" bash run.sh --no-git >/dev/null 2>&1 </dev/null; echo $?)

if [ "$REJECT_STATUS" -eq 0 ]; then
    fail_test "run.sh accepted a backup directory inside docs/"
elif printf '%s' "$REJECT_OUTPUT" | grep -q "GRQ_BACKUP_DIR must be outside"; then
    pass_test "a backup directory inside docs/ is refused with a clear error"
else
    fail_test "run.sh exited ${REJECT_STATUS} but did not say why: ${REJECT_OUTPUT}"
fi

echo ""
echo "=============================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
