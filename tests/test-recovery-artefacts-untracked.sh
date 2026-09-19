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
# GRQ_BACKUP_DIR is cleared first: the shipped assignment honours it, so an
# override in the runner's environment would silently change what is asserted.
# A missing assignment fails the test rather than falling through to a
# hardcoded default that would keep passing after the variable was renamed.
unset GRQ_BACKUP_DIR
for shipped_var in JSON_BACKUP_DIR JSON_BACKUP_FILE; do
    shipped_line=$(grep "^${shipped_var}=" "$RUN_SH" || true)
    if [ -z "$shipped_line" ]; then
        echo "  FAIL: run.sh no longer defines ${shipped_var}"
        exit 1
    fi
    eval "$shipped_line"
done
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

# --- Test 6: run.sh validates the Issue #211 tunables at startup -----------
# A backup directory under docs/ would be staged by the heartbeat's
# `git add docs/`, which is the bug this change removes. run.sh must refuse it
# before doing any work rather than quietly re-creating the bug.
#
# run.sh is copied into a sandbox rather than invoked in $REPO_ROOT: these cases
# exist precisely to catch a regression in the guards, and a regressed guard
# would let the script run a real heartbeat against the developer's checkout.
echo "Test 6: run.sh validates the Issue #211 tunables at startup..."
SANDBOX="$WORK_DIR/sandbox"
mkdir -p "$SANDBOX/docs" "$SANDBOX/helpers"
cp "$RUN_SH" "$SANDBOX/run.sh"
printf '{}\n' > "$SANDBOX/docs/index.json"

# Usage: run_sandboxed <VAR=value> ... — prints the status then the output.
run_sandboxed() {
    local status=0
    local output
    output=$(cd "$SANDBOX" && env "$@" bash run.sh --no-git 2>&1 </dev/null) || status=$?
    printf '%s\n' "$status"
    printf '%s\n' "$output"
}

REJECT=$(run_sandboxed GRQ_BACKUP_DIR="docs/state")
REJECT_STATUS=$(printf '%s' "$REJECT" | head -n 1)
REJECT_OUTPUT=$(printf '%s' "$REJECT" | tail -n +2)

if [ "$REJECT_STATUS" -eq 0 ]; then
    fail_test "run.sh accepted a backup directory inside docs/"
elif printf '%s' "$REJECT_OUTPUT" | grep -q "GRQ_BACKUP_DIR must be outside"; then
    pass_test "a backup directory inside docs/ is refused with a clear error"
else
    fail_test "run.sh exited ${REJECT_STATUS} but did not say why: ${REJECT_OUTPUT}"
fi

# An unrelated directory that merely happens to be called "docs" is legitimate:
# the guard must reject the published tree, not every path with that name.
OUTSIDE=$(run_sandboxed GRQ_BACKUP_DIR="/tmp/var-lib-docs-$$")
OUTSIDE_OUTPUT=$(printf '%s' "$OUTSIDE" | tail -n +2)
if printf '%s' "$OUTSIDE_OUTPUT" | grep -q "GRQ_BACKUP_DIR must be outside"; then
    fail_test "an out-of-repo directory named docs was wrongly refused"
else
    pass_test "an out-of-repo path containing 'docs' is accepted"
fi

# A misconfigured cap must fail at startup, not on some later heartbeat that
# happens to find a log file (the validation inside copy_log_tail is only
# reached when one exists).
CAP=$(run_sandboxed GRQ_LOG_TAIL_BYTES="abc")
CAP_STATUS=$(printf '%s' "$CAP" | head -n 1)
CAP_OUTPUT=$(printf '%s' "$CAP" | tail -n +2)
if [ "$CAP_STATUS" -eq 0 ]; then
    fail_test "run.sh accepted a non-numeric GRQ_LOG_TAIL_BYTES"
elif printf '%s' "$CAP_OUTPUT" | grep -q "GRQ_LOG_TAIL_BYTES must be a positive integer"; then
    pass_test "a non-numeric cap is refused at startup, before any heartbeat"
else
    fail_test "run.sh exited ${CAP_STATUS} but did not say why: ${CAP_OUTPUT}"
fi

# --help must still work: the guards run after argument parsing, so a
# misconfigured tunable must not stop the script explaining itself.
HELP_STATUS=$(cd "$SANDBOX" && GRQ_BACKUP_DIR="docs/state" bash run.sh --help >/dev/null 2>&1 </dev/null; echo $?)
if [ "$HELP_STATUS" -ne 0 ]; then
    fail_test "run.sh --help exited ${HELP_STATUS} with a misconfigured tunable"
else
    pass_test "run.sh --help still works with a misconfigured tunable"
fi

echo ""
echo "=============================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
