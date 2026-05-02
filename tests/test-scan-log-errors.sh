#!/bin/bash
# Test for Issue #59: Falsely flagged as an error
# Verifies that scan_log_errors does not count normal concurrency
# situations as errors (e.g., cache files missing after cleanup)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"

echo "Testing Issue #59: scan_log_errors false positive detection"
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

# Create a temporary directory for test log files
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Extract the scan_log_errors function from run.sh
eval "$(sed -n '/^scan_log_errors()/,/^}/p' "$RUN_SH")"

# Test 1: Cache file not found should NOT be flagged as an error
echo "Test 1: Cache file not found after cleanup is not an error..."
LOG_FILE="$WORK_DIR/test1.log"
cat > "$LOG_FILE" << 'EOF'
run_core pid=20689 start=Sat Mar  7 21:30:59 AEDT 2026
================ Clean up START ================
  Removing .cache/
Emergency cleanup complete.
./cleanup_cache.sh: line 48: .cache/last_cleanup-v2: No such file or directory
Option: IntelligentDesign
HEAD is now at 8f0cfaf Evolution score 0.4065 -> 0.4066
EOF

# Override log_file for scan_log_errors
HOME="$WORK_DIR"
mkdir -p "$WORK_DIR/logs"
cp "$LOG_FILE" "$WORK_DIR/logs/node.log"
# NODE_PID is read by the eval'd scan_log_errors function from run.sh
# shellcheck disable=SC2034
NODE_PID=""
scan_log_errors

# exception_count and exception_summary are set as globals inside scan_log_errors
# shellcheck disable=SC2154
if [ "$exception_count" -eq 0 ]; then
    pass_test "Cache file not found is not flagged as error (count=$exception_count)"
else
    # shellcheck disable=SC2154
    fail_test "Cache file not found was falsely flagged: $exception_summary"
fi

# Test 2: Git push rejection with resolution should NOT be an error
echo "Test 2: Git push rejection (concurrency) is not an error..."
LOG_FILE="$WORK_DIR/test2.log"
cat > "$LOG_FILE" << 'EOF'
[main 796b572fc] Tacit Knowledge, score: 0.406620
 2 files changed, 14 insertions(+), 10 deletions(-)
To github.com:stSoftwareAU/GRQ-sampler.git
 ! [rejected]            main -> main (fetch first)
error: failed to push some refs to 'github.com:stSoftwareAU/GRQ-sampler.git'
hint: Updates were rejected because the remote contains work that you do not
hint: have locally. This is usually caused by another repository pushing to
hint: the same ref. If you want to integrate the remote changes, use
hint: 'git pull' before pushing again.
Git push failed - attempting conflict resolution
No local changes to save
HEAD is now at 70d7da655 GRQ-24, Score: 0.406619
Everything up-to-date
Git push after conflict resolution succeeded.
EOF

cp "$LOG_FILE" "$WORK_DIR/logs/node.log"
scan_log_errors

if [ "$exception_count" -eq 0 ]; then
    pass_test "Git push rejection is not flagged as error (count=$exception_count)"
else
    fail_test "Git push rejection was falsely flagged: $exception_summary"
fi

# Test 3: Real stack trace errors SHOULD still be detected
echo "Test 3: Real stack trace errors are still detected..."
LOG_FILE="$WORK_DIR/test3.log"
cat > "$LOG_FILE" << 'EOF'
2026-03-07T10:35:47.452Z [INFO] Starting process
Error: Something went wrong
    at Object.runInContext (vm.js:130:16)
    at main (index.js:52:8)
EOF

cp "$LOG_FILE" "$WORK_DIR/logs/node.log"
scan_log_errors

if [ "$exception_count" -gt 0 ]; then
    pass_test "Real stack trace error detected (count=$exception_count)"
else
    fail_test "Real stack trace error was NOT detected"
fi

# Test 4: Real missing script errors SHOULD still be detected
echo "Test 4: Real missing script errors are still detected..."
LOG_FILE="$WORK_DIR/test4.log"
cat > "$LOG_FILE" << 'EOF'
run_core pid=20689
./worker/node.sh: line 50: ./important_script.sh: No such file or directory
EOF

cp "$LOG_FILE" "$WORK_DIR/logs/node.log"
scan_log_errors

if [ "$exception_count" -gt 0 ]; then
    pass_test "Real missing script error detected (count=$exception_count)"
else
    fail_test "Real missing script error was NOT detected"
fi

# Test 5: Clean log should have zero errors
echo "Test 5: Clean log has zero errors..."
LOG_FILE="$WORK_DIR/test5.log"
cat > "$LOG_FILE" << 'EOF'
run_core pid=20689 start=Sat Mar  7 21:30:59 AEDT 2026
================ Clean up START ================
Version 1.3.14
Option: IntelligentDesign
HEAD is now at 8f0cfaf Evolution score 0.4065 -> 0.4066
EOF

cp "$LOG_FILE" "$WORK_DIR/logs/node.log"
scan_log_errors

if [ "$exception_count" -eq 0 ]; then
    pass_test "Clean log has zero errors (count=$exception_count)"
else
    fail_test "Clean log falsely flagged: $exception_summary"
fi

# Test 6: The actual GRQ-24 node-sloth.log should not have false positives
echo "Test 6: GRQ-24 node-sloth.log from the issue has no false positives..."
ISSUE_LOG="$SCRIPT_DIR/../docs/GRQ-24/node-sloth.log"
if [ -f "$ISSUE_LOG" ]; then
    cp "$ISSUE_LOG" "$WORK_DIR/logs/node.log"
    scan_log_errors

    if [ "$exception_count" -eq 0 ]; then
        pass_test "GRQ-24 node-sloth.log correctly has zero errors (count=$exception_count)"
    else
        fail_test "GRQ-24 node-sloth.log falsely flagged: $exception_summary"
    fi
else
    echo "  SKIP: GRQ-24 node-sloth.log not found"
fi

# Summary
echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
