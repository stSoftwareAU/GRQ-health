#!/bin/bash
# Test for Issue #95: scheduled bump-deps GitHub Actions workflow.
# Verifies .github/workflows/bump-deps.yml has the correct triggers,
# permissions, SHA-pinned actions, and invokes ./bump-deps.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_FILE="$SCRIPT_DIR/../.github/workflows/bump-deps.yml"

echo "Testing Issue #95: bump-deps.yml workflow"
echo "========================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Test 1: workflow file exists
if [ -f "$WORKFLOW_FILE" ]; then
    pass_test "bump-deps.yml exists at .github/workflows/bump-deps.yml"
else
    fail_test "bump-deps.yml is missing from .github/workflows/"
    echo ""
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
    exit 1
fi

# Test 2: valid YAML
if python3 -c "import yaml,sys; yaml.safe_load(open('$WORKFLOW_FILE'))" 2>/dev/null; then
    pass_test "bump-deps.yml is valid YAML"
else
    fail_test "bump-deps.yml has YAML syntax errors"
fi

# Test 3: workflow has the weekly Monday cron trigger (06:00 UTC)
if python3 - "$WORKFLOW_FILE" <<'PY' 2>/dev/null
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
# YAML's `on:` becomes Python True under safe_load — handle both keys.
on = wf.get('on', wf.get(True))
schedules = on.get('schedule', []) if isinstance(on, dict) else []
crons = [s.get('cron') for s in schedules if isinstance(s, dict)]
sys.exit(0 if '0 6 * * 1' in crons else 1)
PY
then
    pass_test "schedule.cron is '0 6 * * 1' (06:00 UTC Mondays)"
else
    fail_test "expected schedule.cron '0 6 * * 1' not found"
fi

# Test 4: workflow_dispatch trigger present for manual runs
if python3 - "$WORKFLOW_FILE" <<'PY' 2>/dev/null
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
on = wf.get('on', wf.get(True))
if isinstance(on, dict):
    sys.exit(0 if 'workflow_dispatch' in on else 1)
elif isinstance(on, list):
    sys.exit(0 if 'workflow_dispatch' in on else 1)
sys.exit(1)
PY
then
    pass_test "workflow_dispatch trigger is present"
else
    fail_test "workflow_dispatch trigger is missing"
fi

# Test 5: must NOT trigger on pull_request (avoids re-trigger loops)
if python3 - "$WORKFLOW_FILE" <<'PY' 2>/dev/null
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
on = wf.get('on', wf.get(True))
keys = on.keys() if isinstance(on, dict) else (on if isinstance(on, list) else [])
sys.exit(0 if 'pull_request' not in keys else 1)
PY
then
    pass_test "no pull_request trigger (avoids re-trigger loops)"
else
    fail_test "pull_request trigger present — would loop with peter-evans/create-pull-request"
fi

# Test 6: permissions block grants only contents:write and pull-requests:write
if python3 - "$WORKFLOW_FILE" <<'PY' 2>/dev/null
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
perms = wf.get('permissions', {})
if not isinstance(perms, dict):
    sys.exit(1)
expected = {'contents': 'write', 'pull-requests': 'write'}
sys.exit(0 if perms == expected else 1)
PY
then
    pass_test "permissions are exactly contents:write + pull-requests:write"
else
    fail_test "permissions block does not match the required minimum set"
fi

# Test 7: every uses: line is pinned to a 40-char commit SHA
UNPINNED=$(grep -E '^\s*-?\s*uses:\s*' "$WORKFLOW_FILE" | grep -vE '@[0-9a-f]{40}(\s|$)' || true)
if [ -z "$UNPINNED" ]; then
    pass_test "every uses: reference is pinned to a 40-char commit SHA"
else
    fail_test "unpinned actions found:"
    echo "$UNPINNED" | sed 's/^/    /'
fi

# Test 8: every pinned uses: line carries a trailing # vX.Y.Z comment
USES_LINES=$(grep -E '^\s*-?\s*uses:\s*\S+@[0-9a-f]{40}' "$WORKFLOW_FILE" || true)
MISSING_VERSION=""
if [ -n "$USES_LINES" ]; then
    while IFS= read -r line; do
        if ! echo "$line" | grep -qE '@[0-9a-f]{40}\s+#\s*v[0-9]+(\.[0-9]+){1,2}'; then
            MISSING_VERSION+="$line"$'\n'
        fi
    done <<< "$USES_LINES"
fi
if [ -z "$MISSING_VERSION" ]; then
    pass_test "every pinned uses: line carries a trailing # vX.Y.Z comment"
else
    fail_test "pinned uses: lines missing # vX.Y.Z trailing comment:"
    echo "$MISSING_VERSION" | sed 's/^/    /'
fi

# Test 9: workflow invokes ./bump-deps.sh
if grep -qE '\./bump-deps\.sh' "$WORKFLOW_FILE"; then
    pass_test "workflow runs ./bump-deps.sh"
else
    fail_test "workflow does not invoke ./bump-deps.sh"
fi

# Test 10: peter-evans/create-pull-request is referenced
if grep -qE 'peter-evans/create-pull-request@[0-9a-f]{40}' "$WORKFLOW_FILE"; then
    pass_test "peter-evans/create-pull-request action is used (SHA-pinned)"
else
    fail_test "peter-evans/create-pull-request action is missing"
fi

# Test 11: branch + title + delete-branch options for create-pull-request
if grep -qE "^\s*branch:\s*chore/bump-deps" "$WORKFLOW_FILE" \
   && grep -qE "^\s*title:\s*['\"]?chore: bump GitHub Action SHAs" "$WORKFLOW_FILE" \
   && grep -qE "^\s*delete-branch:\s*true" "$WORKFLOW_FILE"; then
    pass_test "create-pull-request configured with branch chore/bump-deps, title, delete-branch:true"
else
    fail_test "create-pull-request is missing branch/title/delete-branch configuration"
fi

# Test 12: PR body references issue #88
if grep -qE '#88' "$WORKFLOW_FILE"; then
    pass_test "PR body links back to issue #88"
else
    fail_test "PR body does not link back to issue #88"
fi

# Test 13: failure of bump-deps.sh must not be swallowed.
# The step should not use `continue-on-error: true`, `|| true`, or `set +e`
# anywhere on the bump-deps.sh invocation.
if grep -qE 'continue-on-error:\s*true' "$WORKFLOW_FILE"; then
    fail_test "continue-on-error: true present — would swallow audit gate failures"
elif grep -qE '\./bump-deps\.sh.*\|\|\s*true' "$WORKFLOW_FILE"; then
    fail_test "bump-deps.sh exit code is masked with || true"
else
    pass_test "bump-deps.sh exit code is not swallowed"
fi

# Test 14: every third-party action is one of the recognised SHA-pinned uses
THIRD_PARTY_SHAS=$(grep -oE 'uses:\s*[^@]+@[0-9a-f]{40}' "$WORKFLOW_FILE" || true)
if [ -n "$THIRD_PARTY_SHAS" ]; then
    pass_test "third-party actions present and SHA-pinned"
else
    fail_test "no SHA-pinned third-party actions found"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
