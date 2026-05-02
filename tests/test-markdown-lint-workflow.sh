#!/bin/bash
# Test for Issue #109: Markdown Lint workflow
# Verifies that .github/workflows/markdown-lint.yml exists, is valid YAML,
# and is wired up correctly (PR + push triggers, read-only permissions,
# markdownlint-cli2 install + run steps, SHA-pinned actions).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_FILE="$SCRIPT_DIR/../.github/workflows/markdown-lint.yml"

echo "Testing Issue #109: Markdown Lint workflow"
echo "=========================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Test 1: workflow file exists
if [ -f "$WORKFLOW_FILE" ]; then
    pass_test "markdown-lint.yml exists at .github/workflows/markdown-lint.yml"
else
    fail_test "markdown-lint.yml is missing from .github/workflows/"
    echo ""
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
    exit 1
fi

# Test 2: valid YAML
if python3 -c "import yaml,sys; yaml.safe_load(open('$WORKFLOW_FILE'))" 2>/dev/null; then
    pass_test "markdown-lint.yml is valid YAML"
else
    fail_test "markdown-lint.yml has YAML syntax errors"
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

# Test 3: name set to "Markdown Lint"
NAME=$(run_yaml "print(wf.get('name',''))")
if [ "$NAME" = "Markdown Lint" ]; then
    pass_test "Workflow name is 'Markdown Lint'"
else
    fail_test "Workflow name is '$NAME', expected 'Markdown Lint'"
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

# Test 6: markdownlint job exists and runs on ubuntu-latest
JOB_RUNS_ON=$(run_yaml "print(((wf.get('jobs') or {}).get('markdownlint') or {}).get('runs-on',''))")
if [ "$JOB_RUNS_ON" = "ubuntu-latest" ]; then
    pass_test "markdownlint job runs on ubuntu-latest"
else
    fail_test "markdownlint job runs-on is '$JOB_RUNS_ON', expected ubuntu-latest"
fi

# Test 7: setup-node step is present
HAS_SETUP_NODE=$(run_yaml "
steps=((wf.get('jobs') or {}).get('markdownlint') or {}).get('steps') or []
print('yes' if any('actions/setup-node' in str(s.get('uses','')) for s in steps) else 'no')
")
if [ "$HAS_SETUP_NODE" = "yes" ]; then
    pass_test "actions/setup-node step is present"
else
    fail_test "Missing actions/setup-node step"
fi

# Test 8: install + run markdownlint-cli2 steps are present
HAS_INSTALL=$(run_yaml "
steps=((wf.get('jobs') or {}).get('markdownlint') or {}).get('steps') or []
print('yes' if any('markdownlint-cli2' in str(s.get('run','')) and 'install' in str(s.get('run','')) for s in steps) else 'no')
")
if [ "$HAS_INSTALL" = "yes" ]; then
    pass_test "markdownlint-cli2 install step present"
else
    fail_test "Missing markdownlint-cli2 install step"
fi

HAS_RUN=$(run_yaml "
steps=((wf.get('jobs') or {}).get('markdownlint') or {}).get('steps') or []
ok=False
for s in steps:
    run=str(s.get('run',''))
    if 'markdownlint-cli2' in run and 'install' not in run:
        ok=True
        break
print('yes' if ok else 'no')
")
if [ "$HAS_RUN" = "yes" ]; then
    pass_test "markdownlint-cli2 run step present"
else
    fail_test "Missing markdownlint-cli2 run step"
fi

# Test 9: every `uses:` reference is pinned to a 40-char commit SHA, not a tag
UNPINNED=$(grep -E '^\s*-?\s*uses:\s*' "$WORKFLOW_FILE" | grep -vE '@[0-9a-f]{40}(\s|$)' || true)
if [ -z "$UNPINNED" ]; then
    pass_test "All uses: references are pinned to 40-char commit SHAs"
else
    fail_test "Unpinned actions found:"
    echo "$UNPINNED" | sed 's/^/    /'
fi

# Test 10: a markdownlint config exists at the repo root so the lint passes
CONFIG_FILE="$SCRIPT_DIR/../.markdownlint-cli2.jsonc"
if [ -f "$CONFIG_FILE" ]; then
    pass_test ".markdownlint-cli2.jsonc config exists at repo root"
else
    fail_test ".markdownlint-cli2.jsonc config is missing"
fi

# Test 11: running markdownlint-cli2 locally against the repo passes (if installed)
if command -v markdownlint-cli2 >/dev/null 2>&1; then
    cd "$SCRIPT_DIR/.." || exit 1
    if markdownlint-cli2 >/tmp/markdownlint-out-109.log 2>&1 < /dev/null; then
        pass_test "markdownlint-cli2 passes against current repo content"
    else
        fail_test "markdownlint-cli2 reports issues:"
        sed 's/^/    /' /tmp/markdownlint-out-109.log | tail -20
    fi
else
    echo "  SKIP: markdownlint-cli2 not installed locally"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
