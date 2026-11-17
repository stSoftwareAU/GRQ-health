#!/bin/bash
# Test for Issue #76: Failure reporting in repos.sh
# Verifies that --failed --log flags work correctly, log retention is enforced,
# and task name sanitisation prevents path traversal and shell injection.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_SCRIPT="$SCRIPT_DIR/../helpers/repos.sh"

echo "Testing Issue #76: Failure reporting in repos.sh"
echo "================================================="
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

# Create a temp directory to simulate the project structure
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

setup_test_env() {
    local test_dir="$TMPDIR_BASE/test_$$_$RANDOM"
    mkdir -p "$test_dir/docs" "$test_dir/helpers"

    # Create a minimal repos.json
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

    # Copy the real repos.sh
    cp "$REPOS_SCRIPT" "$test_dir/helpers/repos.sh"
    chmod +x "$test_dir/helpers/repos.sh"

    echo "$test_dir"
}

# --------------------------------------------------------------------------
# Test 1: Success call is unchanged and still records last_commit_ts
# --------------------------------------------------------------------------
echo "Test 1: Success call records last_commit_ts..."
TEST_DIR=$(setup_test_env)

# Use --dry-run to test without git operations
bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Quality" 2>/dev/null

UPDATED_TS=$(jq '.repos[] | select(.name == "Quality") | .last_commit_ts' "$TEST_DIR/docs/repos.json")
if [ "$UPDATED_TS" -gt 1776265324 ] 2>/dev/null; then
    pass_test "success call updated last_commit_ts"
else
    fail_test "success call did not update last_commit_ts (got: $UPDATED_TS)"
fi

# Verify no failure fields exist
FAILURE_TS=$(jq '.repos[] | select(.name == "Quality") | .last_failure_ts // empty' "$TEST_DIR/docs/repos.json")
if [ -z "$FAILURE_TS" ]; then
    pass_test "success call does not add last_failure_ts"
else
    fail_test "success call unexpectedly added last_failure_ts: $FAILURE_TS"
fi

# --------------------------------------------------------------------------
# Test 2: --failed --log <file> writes log and updates failure fields
# --------------------------------------------------------------------------
echo "Test 2: --failed --log <file> records failure..."
TEST_DIR=$(setup_test_env)

# Create a fake log file
LOG_FILE="$TMPDIR_BASE/run.log"
echo "Some error output" > "$LOG_FILE"
echo "Another line of errors" >> "$LOG_FILE"

bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Quality" --failed --log "$LOG_FILE" 2>/dev/null

# Check last_failure_ts was set
FAILURE_TS=$(jq '.repos[] | select(.name == "Quality") | .last_failure_ts // empty' "$TEST_DIR/docs/repos.json")
if [ -n "$FAILURE_TS" ] && [ "$FAILURE_TS" -gt 0 ] 2>/dev/null; then
    pass_test "--failed sets last_failure_ts ($FAILURE_TS)"
else
    fail_test "--failed did not set last_failure_ts"
fi

# Check last_failure_log was set
FAILURE_LOG=$(jq -r '.repos[] | select(.name == "Quality") | .last_failure_log // empty' "$TEST_DIR/docs/repos.json")
if [[ "$FAILURE_LOG" == logs/Quality/* ]]; then
    pass_test "--failed sets last_failure_log ($FAILURE_LOG)"
else
    fail_test "--failed did not set last_failure_log correctly (got: $FAILURE_LOG)"
fi

# Check log file was copied
if [ -f "$TEST_DIR/docs/$FAILURE_LOG" ]; then
    LOG_CONTENT=$(cat "$TEST_DIR/docs/$FAILURE_LOG")
    if [[ "$LOG_CONTENT" == *"Some error output"* ]]; then
        pass_test "log file was copied with correct content"
    else
        fail_test "log file content mismatch"
    fi
else
    fail_test "log file was not copied to docs/$FAILURE_LOG"
fi

# Check last_commit_ts was NOT updated
COMMIT_TS=$(jq '.repos[] | select(.name == "Quality") | .last_commit_ts' "$TEST_DIR/docs/repos.json")
if [ "$COMMIT_TS" -eq 1776265324 ]; then
    pass_test "--failed does not update last_commit_ts"
else
    fail_test "--failed unexpectedly updated last_commit_ts (got: $COMMIT_TS)"
fi

# --------------------------------------------------------------------------
# Test 3: --failed --log - reads from stdin
# --------------------------------------------------------------------------
echo "Test 3: --failed --log - reads from stdin..."
TEST_DIR=$(setup_test_env)

echo "stdin error log content" | bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Quality" --failed --log - 2>/dev/null

FAILURE_LOG=$(jq -r '.repos[] | select(.name == "Quality") | .last_failure_log // empty' "$TEST_DIR/docs/repos.json")
if [ -n "$FAILURE_LOG" ] && [ -f "$TEST_DIR/docs/$FAILURE_LOG" ]; then
    LOG_CONTENT=$(cat "$TEST_DIR/docs/$FAILURE_LOG")
    if [[ "$LOG_CONTENT" == *"stdin error log content"* ]]; then
        pass_test "--log - reads from stdin correctly"
    else
        fail_test "--log - content mismatch (got: $LOG_CONTENT)"
    fi
else
    fail_test "--log - did not create log file"
fi

# --------------------------------------------------------------------------
# Test 4: Task slug sanitisation
# --------------------------------------------------------------------------
echo "Test 4: Task slug sanitisation..."
TEST_DIR=$(setup_test_env)
LOG_FILE="$TMPDIR_BASE/run2.log"
echo "test log" > "$LOG_FILE"

# Test with colon in name (e.g., "Scorer:client:luke")
cat > "$TEST_DIR/docs/repos.json" <<'ENDJSON'
{"repos": [{"name": "Scorer:client:luke", "last_commit_ts": 1776265324}]}
ENDJSON

bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Scorer:client:luke" --failed --log "$LOG_FILE" 2>/dev/null
FAILURE_LOG=$(jq -r '.repos[] | select(.name == "Scorer:client:luke") | .last_failure_log // empty' "$TEST_DIR/docs/repos.json")
if [[ "$FAILURE_LOG" == logs/Scorer-client-luke/* ]]; then
    pass_test "colon sanitised to hyphen in slug"
else
    fail_test "colon not sanitised in slug (got: $FAILURE_LOG)"
fi

# Test with spaces in name (e.g., "Vibe Coder:GRQ-23")
cat > "$TEST_DIR/docs/repos.json" <<'ENDJSON'
{"repos": [{"name": "Vibe Coder:GRQ-23", "last_commit_ts": 1776265324}]}
ENDJSON

bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Vibe Coder:GRQ-23" --failed --log "$LOG_FILE" 2>/dev/null
FAILURE_LOG=$(jq -r '.repos[] | select(.name == "Vibe Coder:GRQ-23") | .last_failure_log // empty' "$TEST_DIR/docs/repos.json")
if [[ "$FAILURE_LOG" == logs/Vibe-Coder-GRQ-23/* ]]; then
    pass_test "spaces and colons sanitised in slug"
else
    fail_test "spaces and colons not sanitised (got: $FAILURE_LOG)"
fi

# --------------------------------------------------------------------------
# Test 5: Path traversal rejected
# --------------------------------------------------------------------------
echo "Test 5: Path traversal and invalid log paths rejected..."

TEST_DIR=$(setup_test_env)

# Test ../escape in log path
if bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Quality" --failed --log "../../../etc/passwd" 2>/dev/null; then
    fail_test "accepted path traversal with ../"
else
    pass_test "rejected path traversal with ../"
fi

# Test absolute path outside project
if bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Quality" --failed --log "/etc/passwd" 2>/dev/null; then
    fail_test "accepted absolute path outside project"
else
    pass_test "rejected absolute path outside project"
fi

# Test non-existent log file
if bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Quality" --failed --log "/tmp/nonexistent_log_$$.log" 2>/dev/null; then
    fail_test "accepted non-existent log file"
else
    pass_test "rejected non-existent log file"
fi

# Test symlink outside project (if possible to create)
SYMLINK_PATH="$TMPDIR_BASE/evil_symlink.log"
if ln -s /etc/passwd "$SYMLINK_PATH" 2>/dev/null; then
    if bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Quality" --failed --log "$SYMLINK_PATH" 2>/dev/null; then
        fail_test "accepted symlink pointing outside project"
    else
        pass_test "rejected symlink pointing outside project"
    fi
else
    echo "  SKIP: could not create symlink for test"
fi

# --------------------------------------------------------------------------
# Test 6: Log retention — after 6 failures only 5 log files remain
# --------------------------------------------------------------------------
echo "Test 6: Log retention (max 5 files)..."
TEST_DIR=$(setup_test_env)

for i in $(seq 1 6); do
    LOG_FILE="$TMPDIR_BASE/retention_$i.log"
    echo "Failure log $i" > "$LOG_FILE"
    # Need slight delay so timestamps differ
    bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" --skip-rate-limit "Quality" --failed --log "$LOG_FILE" 2>/dev/null
done

LOG_COUNT=$(find "$TEST_DIR/docs/logs/Quality" -name "*.log" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$LOG_COUNT" -le 5 ]; then
    pass_test "retention enforced: $LOG_COUNT log files (max 5)"
else
    fail_test "retention not enforced: $LOG_COUNT log files (expected <= 5)"
fi

# --------------------------------------------------------------------------
# Test 7: Optional --exit-code and --message flags
# --------------------------------------------------------------------------
echo "Test 7: Optional --exit-code and --message flags..."
TEST_DIR=$(setup_test_env)
LOG_FILE="$TMPDIR_BASE/optional.log"
echo "test" > "$LOG_FILE"

bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Quality" --failed --log "$LOG_FILE" --exit-code 42 --message "3 shellcheck errors" 2>/dev/null

EXIT_CODE=$(jq '.repos[] | select(.name == "Quality") | .last_failure_exit_code // empty' "$TEST_DIR/docs/repos.json")
if [ "$EXIT_CODE" = "42" ]; then
    pass_test "--exit-code recorded correctly"
else
    fail_test "--exit-code not recorded (got: $EXIT_CODE)"
fi

MESSAGE=$(jq -r '.repos[] | select(.name == "Quality") | .last_failure_message // empty' "$TEST_DIR/docs/repos.json")
if [ "$MESSAGE" = "3 shellcheck errors" ]; then
    pass_test "--message recorded correctly"
else
    fail_test "--message not recorded (got: $MESSAGE)"
fi

# --------------------------------------------------------------------------
# Test 8: --failed without --log should fail
# --------------------------------------------------------------------------
echo "Test 8: --failed requires --log..."
TEST_DIR=$(setup_test_env)

if bash "$TEST_DIR/helpers/repos.sh" --dry-run --project-root "$TEST_DIR" "Quality" --failed 2>/dev/null; then
    fail_test "--failed without --log was accepted"
else
    pass_test "--failed without --log was rejected"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
