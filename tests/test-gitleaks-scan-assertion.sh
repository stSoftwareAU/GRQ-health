#!/bin/bash
# Test for Issue #166: the gitleaks workflow test must assert the OUTCOME
# (a secret scan runs) rather than one particular mechanism.
#
# Runs tests/test-gitleaks-workflow.sh against fixture workflows to prove:
#   * the action form (gitleaks/gitleaks-action) is accepted,
#   * the CLI form (gitleaks detect) is accepted,
#   * a workflow with no secret scan at all is REJECTED, so the gate still bites.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_TEST="$SCRIPT_DIR/test-gitleaks-workflow.sh"
FIXTURES="$SCRIPT_DIR/fixtures/gitleaks"

echo "Testing Issue #166: gitleaks workflow assertion is outcome-based"
echo "================================================================"
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Run the workflow test against a fixture, setting OUTPUT and STATUS.
# Assigns globals directly — a command substitution would run in a subshell and
# lose OUTPUT.
OUTPUT=""
STATUS=0
run_against_fixture() {
    local fixture="$1"
    STATUS=0
    OUTPUT=$(GITLEAKS_WORKFLOW_FILE="$FIXTURES/$fixture" "$WORKFLOW_TEST" 2>&1 < /dev/null) || STATUS=$?
}

# Test 1: the workflow test itself is executable
if [ -x "$WORKFLOW_TEST" ]; then
    pass_test "test-gitleaks-workflow.sh is executable"
else
    fail_test "test-gitleaks-workflow.sh is missing or not executable"
    echo ""
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
    exit 1
fi

# Test 2: the workflow test honours GITLEAKS_WORKFLOW_FILE (needed to test it at all)
run_against_fixture "cli-form.yml"
if echo "$OUTPUT" | grep -q "gitleaks.yml exists"; then
    pass_test "GITLEAKS_WORKFLOW_FILE override is honoured"
else
    fail_test "GITLEAKS_WORKFLOW_FILE override is ignored"
    echo "$OUTPUT" | sed 's/^/    /'
fi

# Test 3: CLI form (gitleaks detect from the pinned release) is accepted
if [ "$STATUS" -eq 0 ]; then
    pass_test "CLI form (gitleaks detect) passes the workflow test"
else
    fail_test "CLI form rejected — exit $STATUS"
    echo "$OUTPUT" | sed 's/^/    /'
fi

# Test 4: action form (gitleaks/gitleaks-action) is accepted
run_against_fixture "action-form.yml"
if [ "$STATUS" -eq 0 ]; then
    pass_test "Action form (gitleaks/gitleaks-action) passes the workflow test"
else
    fail_test "Action form rejected — exit $STATUS"
    echo "$OUTPUT" | sed 's/^/    /'
fi

# Test 5: a workflow with no secret scan is rejected — the gate still bites
run_against_fixture "no-scan.yml"
if [ "$STATUS" -ne 0 ]; then
    pass_test "Workflow with no secret scan is rejected"
else
    fail_test "Workflow with no secret scan was accepted — gate is toothless"
    echo "$OUTPUT" | sed 's/^/    /'
fi

# Test 6: the rejection names the missing scan, not a missing action
if echo "$OUTPUT" | grep -qi "secret scan"; then
    pass_test "Rejection message reports the missing secret scan"
else
    fail_test "Rejection message does not mention the missing secret scan"
    echo "$OUTPUT" | sed 's/^/    /'
fi

# Test 7: the real workflow still passes
STATUS=0
REAL_OUTPUT=$("$WORKFLOW_TEST" 2>&1 < /dev/null) || STATUS=$?
if [ "$STATUS" -eq 0 ]; then
    pass_test "The committed .github/workflows/gitleaks.yml passes"
else
    fail_test "The committed gitleaks.yml fails the workflow test — exit $STATUS"
    echo "$REAL_OUTPUT" | sed 's/^/    /'
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
