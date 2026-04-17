#!/bin/bash
# Test for Issue #78: report_repo_health helper function in repo-health-snippet.sh
# Verifies that callers can source the helper and use a single function call to
# report both success and failure paths to repos.sh.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNIPPET_SCRIPT="$SCRIPT_DIR/../helpers/repo-health-snippet.sh"

echo "Testing Issue #78: report_repo_health helper"
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

# Create a test environment with a stub repos.sh that records invocations
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

setup_test_env() {
    local test_dir="$TMPDIR_BASE/test_$$_$RANDOM"
    mkdir -p "$test_dir/helpers"

    # Create a stub repos.sh that records its invocation arguments
    cat > "$test_dir/helpers/repos.sh" <<'STUB'
#!/bin/bash
# Stub repos.sh — records arguments to a file for test assertions
INVOCATIONS_FILE="${INVOCATIONS_FILE:-/tmp/invocations.txt}"
printf '%s\n' "$*" >> "$INVOCATIONS_FILE"
exit 0
STUB
    chmod +x "$test_dir/helpers/repos.sh"

    echo "$test_dir"
}

# --------------------------------------------------------------------------
# Test 1: report_repo_health is defined as a function after sourcing
# --------------------------------------------------------------------------
echo "Test 1: sourcing the snippet defines report_repo_health..."

# Run in a subshell to avoid polluting the parent shell
RESULT=$(
    # shellcheck disable=SC1090
    source "$SNIPPET_SCRIPT" 2>/dev/null
    if declare -f report_repo_health >/dev/null 2>&1; then
        echo "DEFINED"
    else
        echo "MISSING"
    fi
)

if [ "$RESULT" = "DEFINED" ]; then
    pass_test "report_repo_health is defined after sourcing"
else
    fail_test "report_repo_health is not defined after sourcing"
fi

# --------------------------------------------------------------------------
# Test 2: Success path — repos.sh called with just the task name
# --------------------------------------------------------------------------
echo "Test 2: success path invokes repos.sh with task name only..."
TEST_DIR=$(setup_test_env)
INVOCATIONS_FILE="$TEST_DIR/invocations.txt"
: > "$INVOCATIONS_FILE"
export INVOCATIONS_FILE

LOG_FILE="$TEST_DIR/task.log"
echo "some log output" > "$LOG_FILE"

(
    export GRQ_HEALTH_DIR="$TEST_DIR"
    # shellcheck disable=SC1090
    source "$SNIPPET_SCRIPT"

    # Simulate a successful command by setting $? to 0
    true
    report_repo_health "Quality" "$LOG_FILE"
) 2>/dev/null

if [ -f "$INVOCATIONS_FILE" ]; then
    INVOCATION=$(cat "$INVOCATIONS_FILE")
    if [ "$INVOCATION" = "Quality" ]; then
        pass_test "success call invokes repos.sh with task name"
    else
        fail_test "unexpected invocation (got: '$INVOCATION', expected: 'Quality')"
    fi
else
    fail_test "repos.sh was not invoked"
fi

# --------------------------------------------------------------------------
# Test 3: Failure path — repos.sh called with --failed --log --exit-code
# --------------------------------------------------------------------------
echo "Test 3: failure path invokes repos.sh with --failed --log..."
TEST_DIR=$(setup_test_env)
INVOCATIONS_FILE="$TEST_DIR/invocations.txt"
: > "$INVOCATIONS_FILE"
export INVOCATIONS_FILE

LOG_FILE="$TEST_DIR/task.log"
echo "error details" > "$LOG_FILE"

(
    export GRQ_HEALTH_DIR="$TEST_DIR"
    # shellcheck disable=SC1090
    source "$SNIPPET_SCRIPT"

    # Simulate a failing command by setting $? to 3
    (exit 3)
    report_repo_health "Quality" "$LOG_FILE"
) 2>/dev/null || true

if [ -f "$INVOCATIONS_FILE" ]; then
    INVOCATION=$(cat "$INVOCATIONS_FILE")
    if [[ "$INVOCATION" == *"Quality"* ]] \
       && [[ "$INVOCATION" == *"--failed"* ]] \
       && [[ "$INVOCATION" == *"--log"* ]] \
       && [[ "$INVOCATION" == *"$LOG_FILE"* ]]; then
        pass_test "failure call invokes repos.sh with --failed and --log"
    else
        fail_test "unexpected failure invocation (got: '$INVOCATION')"
    fi

    if [[ "$INVOCATION" == *"--exit-code 3"* ]]; then
        pass_test "failure call records the exit code"
    else
        fail_test "failure call did not record exit code 3 (got: '$INVOCATION')"
    fi
else
    fail_test "repos.sh was not invoked on failure"
fi

# --------------------------------------------------------------------------
# Test 4: Exit code is preserved so caller can propagate it
# --------------------------------------------------------------------------
echo "Test 4: report_repo_health returns the original exit code..."
TEST_DIR=$(setup_test_env)
INVOCATIONS_FILE="$TEST_DIR/invocations.txt"
: > "$INVOCATIONS_FILE"
export INVOCATIONS_FILE

LOG_FILE="$TEST_DIR/task.log"
echo "log" > "$LOG_FILE"

SUBSHELL_EXIT=$(
    (
        export GRQ_HEALTH_DIR="$TEST_DIR"
        # shellcheck disable=SC1090
        source "$SNIPPET_SCRIPT"
        (exit 7)
        report_repo_health "Quality" "$LOG_FILE"
        echo "$?"
    ) 2>/dev/null
)

if [ "$SUBSHELL_EXIT" = "7" ]; then
    pass_test "report_repo_health preserves exit code 7"
else
    fail_test "exit code not preserved (got: '$SUBSHELL_EXIT', expected: 7)"
fi

# --------------------------------------------------------------------------
# Test 5: Success path returns zero
# --------------------------------------------------------------------------
echo "Test 5: success returns zero..."
TEST_DIR=$(setup_test_env)
INVOCATIONS_FILE="$TEST_DIR/invocations.txt"
: > "$INVOCATIONS_FILE"
export INVOCATIONS_FILE

LOG_FILE="$TEST_DIR/task.log"
echo "log" > "$LOG_FILE"

SUBSHELL_EXIT=$(
    (
        export GRQ_HEALTH_DIR="$TEST_DIR"
        # shellcheck disable=SC1090
        source "$SNIPPET_SCRIPT"
        true
        report_repo_health "Quality" "$LOG_FILE"
        echo "$?"
    ) 2>/dev/null
)

if [ "$SUBSHELL_EXIT" = "0" ]; then
    pass_test "report_repo_health returns zero on success"
else
    fail_test "success did not return zero (got: '$SUBSHELL_EXIT')"
fi

# --------------------------------------------------------------------------
# Test 6: GRQ_HEALTH_DIR environment variable is respected
# --------------------------------------------------------------------------
echo "Test 6: GRQ_HEALTH_DIR override is respected..."
TEST_DIR=$(setup_test_env)
INVOCATIONS_FILE="$TEST_DIR/invocations.txt"
: > "$INVOCATIONS_FILE"
export INVOCATIONS_FILE

LOG_FILE="$TEST_DIR/task.log"
echo "log" > "$LOG_FILE"

# Put a unique marker in the stub so we know this particular stub ran
cat > "$TEST_DIR/helpers/repos.sh" <<STUB
#!/bin/bash
echo "CUSTOM_DIR_MARKER \$*" >> "$INVOCATIONS_FILE"
exit 0
STUB
chmod +x "$TEST_DIR/helpers/repos.sh"

(
    export GRQ_HEALTH_DIR="$TEST_DIR"
    # shellcheck disable=SC1090
    source "$SNIPPET_SCRIPT"
    true
    report_repo_health "Quality" "$LOG_FILE"
) 2>/dev/null

if grep -q "CUSTOM_DIR_MARKER Quality" "$INVOCATIONS_FILE"; then
    pass_test "GRQ_HEALTH_DIR override is used"
else
    fail_test "GRQ_HEALTH_DIR override was not used"
fi

# --------------------------------------------------------------------------
# Test 7: Missing arguments are rejected clearly
# --------------------------------------------------------------------------
echo "Test 7: missing arguments rejected..."

SUBSHELL_EXIT=$(
    (
        export GRQ_HEALTH_DIR="$TMPDIR_BASE/does-not-matter"
        # shellcheck disable=SC1090
        source "$SNIPPET_SCRIPT"
        report_repo_health "" ""
        echo "$?"
    ) 2>/dev/null
)

if [ "$SUBSHELL_EXIT" != "0" ]; then
    pass_test "report_repo_health rejects empty task name"
else
    fail_test "report_repo_health accepted empty task name"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "============================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
