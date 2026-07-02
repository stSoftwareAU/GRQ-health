#!/bin/bash
# Test for Issue #122: helpers/repos.sh emits a machine-readable status
# line to stderr so callers that suppress stdout (e.g. the Deno worker's
# runWithTimeout(..., { quiet: true })) can still distinguish between
# pushed / skipped / failed outcomes.
#
# Status line format:
#   repos.sh status=<skipped|updated|added|failed-recorded|failed> \
#            reason=<rate-limited|success|failure-recorded|push-failed|validation-failed> \
#            name='<repo_name>'

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_SCRIPT="$SCRIPT_DIR/../helpers/repos.sh"

echo "Testing Issue #122: repos.sh emits status line to stderr"
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

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

setup_test_env() {
    local test_dir="$TMPDIR_BASE/test_$$_$RANDOM"
    mkdir -p "$test_dir/docs" "$test_dir/helpers"

    cat > "$test_dir/docs/repos.json" <<'ENDJSON'
{
  "repos": [
    {
      "name": "Quality",
      "last_commit_ts": 1776265324
    }
  ]
}
ENDJSON

    cp "$REPOS_SCRIPT" "$test_dir/helpers/repos.sh"
    if [ -f "$SCRIPT_DIR/../helpers/git-retry.sh" ]; then
        cp "$SCRIPT_DIR/../helpers/git-retry.sh" "$test_dir/helpers/git-retry.sh"
    fi
    chmod +x "$test_dir/helpers/repos.sh"

    echo "$test_dir"
}

# --------------------------------------------------------------------------
# Test 1: Rate-limit skip emits status=skipped reason=rate-limited
# --------------------------------------------------------------------------
echo "Test 1: rate-limit skip -> status=skipped reason=rate-limited..."
TEST_DIR=$(setup_test_env)

# Set last_commit_ts to now (so it falls inside the 1-hour window)
NOW=$(date +%s)
cat > "$TEST_DIR/docs/repos.json" <<ENDJSON
{"repos": [{"name": "Quality", "last_commit_ts": ${NOW}}]}
ENDJSON

STDERR_FILE="$TMPDIR_BASE/skip_stderr_$$"
bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Quality" >/dev/null 2>"$STDERR_FILE"
STDERR_CONTENT=$(cat "$STDERR_FILE")

if echo "$STDERR_CONTENT" | grep -qE "repos\.sh status=skipped reason=rate-limited name='Quality'"; then
    pass_test "rate-limit skip emits machine-readable status line on stderr"
else
    fail_test "rate-limit skip status line missing or malformed (got: $STDERR_CONTENT)"
fi

# --------------------------------------------------------------------------
# Test 2: Successful update of existing repo emits status=updated
# --------------------------------------------------------------------------
echo "Test 2: existing-repo update -> status=updated reason=success..."
TEST_DIR=$(setup_test_env)

# last_commit_ts well in the past so rate-limit does not trigger
cat > "$TEST_DIR/docs/repos.json" <<'ENDJSON'
{"repos": [{"name": "Quality", "last_commit_ts": 1}]}
ENDJSON

STDERR_FILE="$TMPDIR_BASE/upd_stderr_$$"
bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Quality" >/dev/null 2>"$STDERR_FILE"
STDERR_CONTENT=$(cat "$STDERR_FILE")

if echo "$STDERR_CONTENT" | grep -qE "repos\.sh status=updated reason=success name='Quality'"; then
    pass_test "update emits status=updated on stderr"
else
    fail_test "update status line missing or malformed (got: $STDERR_CONTENT)"
fi

# --------------------------------------------------------------------------
# Test 3: New repo addition emits status=added
# --------------------------------------------------------------------------
echo "Test 3: new repo -> status=added reason=success..."
TEST_DIR=$(setup_test_env)

STDERR_FILE="$TMPDIR_BASE/add_stderr_$$"
bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "NewRepo" >/dev/null 2>"$STDERR_FILE"
STDERR_CONTENT=$(cat "$STDERR_FILE")

if echo "$STDERR_CONTENT" | grep -qE "repos\.sh status=added reason=success name='NewRepo'"; then
    pass_test "new repo emits status=added on stderr"
else
    fail_test "added status line missing or malformed (got: $STDERR_CONTENT)"
fi

# --------------------------------------------------------------------------
# Test 4: --failed invocation emits status=failed-recorded
# --------------------------------------------------------------------------
echo "Test 4: --failed mode -> status=failed-recorded reason=failure-recorded..."
TEST_DIR=$(setup_test_env)
LOG_FILE="$TMPDIR_BASE/run_$$.log"
echo "Some error output" > "$LOG_FILE"

STDERR_FILE="$TMPDIR_BASE/failrec_stderr_$$"
bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Quality" \
    --failed --log "$LOG_FILE" >/dev/null 2>"$STDERR_FILE"
STDERR_CONTENT=$(cat "$STDERR_FILE")

if echo "$STDERR_CONTENT" | grep -qE "repos\.sh status=failed-recorded reason=failure-recorded name='Quality'"; then
    pass_test "--failed mode emits status=failed-recorded on stderr"
else
    fail_test "failed-recorded status line missing or malformed (got: $STDERR_CONTENT)"
fi

# --------------------------------------------------------------------------
# Test 5: Validation failure emits status=failed reason=validation-failed
# --------------------------------------------------------------------------
echo "Test 5: invalid repo name -> status=failed reason=validation-failed..."
TEST_DIR=$(setup_test_env)

STDERR_FILE="$TMPDIR_BASE/val_stderr_$$"
# Use a name with characters the validator rejects (e.g. semicolon)
bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "bad;name" \
    >/dev/null 2>"$STDERR_FILE" || true
STDERR_CONTENT=$(cat "$STDERR_FILE")

if echo "$STDERR_CONTENT" | grep -qE "repos\.sh status=failed reason=validation-failed"; then
    pass_test "validation failure emits status=failed reason=validation-failed"
else
    fail_test "validation-failed status line missing (got: $STDERR_CONTENT)"
fi

# --------------------------------------------------------------------------
# Test 6: --failed without --log emits status=failed reason=validation-failed
# --------------------------------------------------------------------------
echo "Test 6: --failed without --log -> status=failed reason=validation-failed..."
TEST_DIR=$(setup_test_env)

STDERR_FILE="$TMPDIR_BASE/failval_stderr_$$"
bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Quality" --failed \
    >/dev/null 2>"$STDERR_FILE" || true
STDERR_CONTENT=$(cat "$STDERR_FILE")

if echo "$STDERR_CONTENT" | grep -qE "repos\.sh status=failed reason=validation-failed"; then
    pass_test "--failed without --log emits validation-failed status"
else
    fail_test "missing validation-failed status (got: $STDERR_CONTENT)"
fi

# --------------------------------------------------------------------------
# Test 7: Existing stdout messages are preserved (non-quiet callers see them)
# --------------------------------------------------------------------------
echo "Test 7: existing stdout messages preserved (back-compat)..."
TEST_DIR=$(setup_test_env)
cat > "$TEST_DIR/docs/repos.json" <<'ENDJSON'
{"repos": [{"name": "Quality", "last_commit_ts": 1}]}
ENDJSON

STDOUT_FILE="$TMPDIR_BASE/back_stdout_$$"
bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Quality" \
    >"$STDOUT_FILE" 2>/dev/null
STDOUT_CONTENT=$(cat "$STDOUT_FILE")

if echo "$STDOUT_CONTENT" | grep -qE "Updated repo 'Quality' with timestamp"; then
    pass_test "existing stdout 'Updated repo' message preserved"
else
    fail_test "existing stdout message changed (got: $STDOUT_CONTENT)"
fi

# Rate-limit skip stdout message is also preserved
NOW=$(date +%s)
cat > "$TEST_DIR/docs/repos.json" <<ENDJSON
{"repos": [{"name": "Quality", "last_commit_ts": ${NOW}}]}
ENDJSON
STDOUT_FILE="$TMPDIR_BASE/back2_stdout_$$"
bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Quality" \
    >"$STDOUT_FILE" 2>/dev/null
STDOUT_CONTENT=$(cat "$STDOUT_FILE")

if echo "$STDOUT_CONTENT" | grep -qE "Skipping update for 'Quality'"; then
    pass_test "rate-limit stdout 'Skipping update' message preserved"
else
    fail_test "rate-limit stdout message changed (got: $STDOUT_CONTENT)"
fi

# --------------------------------------------------------------------------
# Test 8: Status line contains the repo name correctly quoted
# --------------------------------------------------------------------------
echo "Test 8: status line quotes repo name with spaces/colons..."
TEST_DIR=$(setup_test_env)
cat > "$TEST_DIR/docs/repos.json" <<'ENDJSON'
{"repos": [{"name": "Vibe Coder:GRQ-23", "last_commit_ts": 1}]}
ENDJSON

STDERR_FILE="$TMPDIR_BASE/spaces_stderr_$$"
bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Vibe Coder:GRQ-23" \
    >/dev/null 2>"$STDERR_FILE"
STDERR_CONTENT=$(cat "$STDERR_FILE")

if echo "$STDERR_CONTENT" | grep -qE "name='Vibe Coder:GRQ-23'"; then
    pass_test "status line includes correctly-quoted repo name with spaces and colons"
else
    fail_test "repo name not correctly quoted in status line (got: $STDERR_CONTENT)"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "========================================================"
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
