#!/bin/bash
# Test for Issue #89: Gitleaks Secrets Detection workflow
# Verifies that .github/workflows/gitleaks.yml exists, is valid YAML,
# and is wired up correctly (PR trigger, read-only permissions, SHA-pinned actions).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# GITLEAKS_WORKFLOW_FILE lets tests/test-gitleaks-scan-assertion.sh point these
# assertions at fixture workflows; defaults to the committed workflow.
WORKFLOW_FILE="${GITLEAKS_WORKFLOW_FILE:-$SCRIPT_DIR/../.github/workflows/gitleaks.yml}"

echo "Testing Issue #89: Gitleaks workflow"
echo "===================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Test 1: workflow file exists
if [ -f "$WORKFLOW_FILE" ]; then
    pass_test "gitleaks.yml exists at .github/workflows/gitleaks.yml"
else
    fail_test "gitleaks.yml is missing from .github/workflows/"
    echo ""
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
    exit 1
fi

# Test 2: valid YAML
if python3 -c "import yaml,sys; yaml.safe_load(open('$WORKFLOW_FILE'))" 2>/dev/null; then
    pass_test "gitleaks.yml is valid YAML"
else
    fail_test "gitleaks.yml has YAML syntax errors"
fi

# Helper that reads YAML directly (PyYAML parses bare `on:` as boolean True,
# so we work with the YAML object rather than round-tripping through JSON).
run_yaml() {
    local code="$1"
    python3 - "$WORKFLOW_FILE" <<PYEOF
import yaml, sys
wf = yaml.safe_load(open(sys.argv[1]))
# YAML parses unquoted "on" as boolean True
on = wf.get('on')
if on is None:
    on = wf.get(True)
$code
PYEOF
}

# Test 3: name set to Gitleaks
NAME=$(run_yaml "print(wf.get('name',''))")
if [ "$NAME" = "Gitleaks" ]; then
    pass_test "Workflow name is 'Gitleaks'"
else
    fail_test "Workflow name is '$NAME', expected 'Gitleaks'"
fi

# Test 4: pull_request trigger present
HAS_PR=$(run_yaml "print('yes' if isinstance(on, dict) and 'pull_request' in on else 'no')")
if [ "$HAS_PR" = "yes" ]; then
    pass_test "Workflow triggers on pull_request"
else
    fail_test "Workflow is missing pull_request trigger"
fi

# Test 5: top-level permissions are read-only (contents: read)
PERM=$(run_yaml "print((wf.get('permissions') or {}).get('contents',''))")
if [ "$PERM" = "read" ]; then
    pass_test "Top-level permissions grant contents: read"
else
    fail_test "Expected permissions.contents = 'read', got '$PERM'"
fi

# Test 6: gitleaks job exists and runs on ubuntu-latest
JOB_RUNS_ON=$(run_yaml "print(((wf.get('jobs') or {}).get('gitleaks') or {}).get('runs-on',''))")
if [ "$JOB_RUNS_ON" = "ubuntu-latest" ]; then
    pass_test "gitleaks job runs on ubuntu-latest"
else
    fail_test "gitleaks job runs-on is '$JOB_RUNS_ON', expected ubuntu-latest"
fi

# Test 7: checkout step uses fetch-depth: 0 (full history for secret scan)
FETCH_DEPTH=$(run_yaml "
steps=((wf.get('jobs') or {}).get('gitleaks') or {}).get('steps') or []
for s in steps:
    if 'checkout' in str(s.get('uses','')):
        print((s.get('with') or {}).get('fetch-depth',''))
        break
")
if [ "$FETCH_DEPTH" = "0" ]; then
    pass_test "checkout step sets fetch-depth: 0"
else
    fail_test "checkout step fetch-depth is '$FETCH_DEPTH', expected 0"
fi

# Test 8: the job actually runs a secret scan.
# Asserts the outcome, not the mechanism — either the gitleaks-action or the
# Gitleaks CLI (`gitleaks detect`) satisfies this, so swapping implementations
# does not re-break the gate. Test 9 covers SHA-pinning of any action used.
HAS_GITLEAKS_STEP=$(run_yaml "
steps=((wf.get('jobs') or {}).get('gitleaks') or {}).get('steps') or []
ok=False
for s in steps:
    uses=str(s.get('uses',''))
    # Collapse whitespace so multi-line/continued run: blocks still match.
    run=' '.join(str(s.get('run','')).split())
    if 'gitleaks/gitleaks-action' in uses or 'gitleaks detect' in run:
        ok=True
        break
print('yes' if ok else 'no')
")
if [ "$HAS_GITLEAKS_STEP" = "yes" ]; then
    pass_test "gitleaks job runs a secret scan (action or gitleaks detect CLI)"
else
    fail_test "gitleaks job runs no secret scan: no gitleaks-action step and no 'gitleaks detect' command"
fi

# Test 9: every `uses:` reference is pinned to a 40-char commit SHA, not a tag
UNPINNED=$(grep -E '^\s*-?\s*uses:\s*' "$WORKFLOW_FILE" | grep -vE '@[0-9a-f]{40}(\s|$)' || true)
if [ -z "$UNPINNED" ]; then
    pass_test "All uses: references are pinned to 40-char commit SHAs"
else
    fail_test "Unpinned actions found:"
    echo "$UNPINNED" | sed 's/^/    /'
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
