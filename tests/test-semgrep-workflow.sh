#!/bin/bash
# Test for Issue #90: Semgrep SAST Scanning workflow
# Verifies that .github/workflows/semgrep.yml exists, is valid YAML,
# and is wired up correctly (PR trigger, read-only permissions, container,
# semgrep ci step, SHA-pinned actions).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_FILE="$SCRIPT_DIR/../.github/workflows/semgrep.yml"

echo "Testing Issue #90: Semgrep workflow"
echo "==================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Test 1: workflow file exists
if [ -f "$WORKFLOW_FILE" ]; then
    pass_test "semgrep.yml exists at .github/workflows/semgrep.yml"
else
    fail_test "semgrep.yml is missing from .github/workflows/"
    echo ""
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
    exit 1
fi

# Test 2: valid YAML
if python3 -c "import yaml,sys; yaml.safe_load(open('$WORKFLOW_FILE'))" 2>/dev/null; then
    pass_test "semgrep.yml is valid YAML"
else
    fail_test "semgrep.yml has YAML syntax errors"
fi

# Helper that reads YAML directly (PyYAML parses bare `on:` as boolean True).
run_yaml() {
    local code="$1"
    python3 - "$WORKFLOW_FILE" <<PYEOF
import yaml, sys
wf = yaml.safe_load(open(sys.argv[1]))
on = wf.get('on')
if on is None:
    on = wf.get(True)
$code
PYEOF
}

# Test 3: name set to Semgrep
NAME=$(run_yaml "print(wf.get('name',''))")
if [ "$NAME" = "Semgrep" ]; then
    pass_test "Workflow name is 'Semgrep'"
else
    fail_test "Workflow name is '$NAME', expected 'Semgrep'"
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

# Test 6: semgrep job exists and runs on ubuntu-latest
JOB_RUNS_ON=$(run_yaml "print(((wf.get('jobs') or {}).get('semgrep') or {}).get('runs-on',''))")
if [ "$JOB_RUNS_ON" = "ubuntu-latest" ]; then
    pass_test "semgrep job runs on ubuntu-latest"
else
    fail_test "semgrep job runs-on is '$JOB_RUNS_ON', expected ubuntu-latest"
fi

# Test 7: semgrep job uses semgrep/semgrep container image
CONTAINER_IMAGE=$(run_yaml "
job = (wf.get('jobs') or {}).get('semgrep') or {}
container = job.get('container')
if isinstance(container, dict):
    print(container.get('image',''))
elif isinstance(container, str):
    print(container)
else:
    print('')
")
if [ "$CONTAINER_IMAGE" = "semgrep/semgrep" ]; then
    pass_test "semgrep job runs in semgrep/semgrep container"
else
    fail_test "Container image is '$CONTAINER_IMAGE', expected semgrep/semgrep"
fi

# Test 8: a step runs `semgrep ci` with a config
HAS_SEMGREP_CI=$(run_yaml "
steps=((wf.get('jobs') or {}).get('semgrep') or {}).get('steps') or []
ok=False
for s in steps:
    run=str(s.get('run',''))
    if 'semgrep ci' in run and '--config' in run:
        ok=True
        break
print('yes' if ok else 'no')
")
if [ "$HAS_SEMGREP_CI" = "yes" ]; then
    pass_test "Step runs 'semgrep ci --config <ruleset>'"
else
    fail_test "No step runs 'semgrep ci' with a --config ruleset"
fi

# Test 9: SEMGREP_APP_TOKEN env wired through to the semgrep step
HAS_TOKEN_ENV=$(run_yaml "
steps=((wf.get('jobs') or {}).get('semgrep') or {}).get('steps') or []
ok=False
for s in steps:
    env=s.get('env') or {}
    if 'SEMGREP_APP_TOKEN' in env:
        ok=True
        break
print('yes' if ok else 'no')
")
if [ "$HAS_TOKEN_ENV" = "yes" ]; then
    pass_test "semgrep step exposes SEMGREP_APP_TOKEN env"
else
    fail_test "No step exposes SEMGREP_APP_TOKEN env"
fi

# Test 10: every `uses:` reference is pinned to a 40-char commit SHA, not a tag
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
