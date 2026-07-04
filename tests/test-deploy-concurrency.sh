#!/bin/bash
# Test for Issue #148: the GitHub Pages deployment action fails with
# "Deployment failed, try again later.".
#
# Root cause: the health monitor pushes docs/** updates to the Develop branch
# very frequently (many hosts, every few minutes). Each push triggers the
# deploy workflow. With concurrency `cancel-in-progress: false`, overlapping
# deployments queue and race on the GitHub Pages backend — a deployment that
# is superseded by a newer one is marked "failed" and the run reports
# "Deployment failed, try again later.".
#
# Fix: set `cancel-in-progress: true` so a newer run cancels an older in-flight
# deployment in the shared "pages" concurrency group. Only the latest (freshest)
# deployment runs, which removes the race. The dashboard always deploys the most
# recent health data, so cancelling a superseded deploy is the desired behaviour.
#
# The test parses the workflow YAML with a real parser and asserts on the
# resulting structure rather than grepping raw text.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_FILE="$SCRIPT_DIR/../.github/workflows/deploy.yml"

echo "Testing Issue #148: deploy.yml concurrency prevents Pages race"
echo "============================================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Test 1: workflow file exists
if [ -f "$WORKFLOW_FILE" ]; then
    pass_test "deploy.yml exists at .github/workflows/deploy.yml"
else
    fail_test "deploy.yml is missing from .github/workflows/"
    echo ""
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
    exit 1
fi

# Test 2: valid YAML
if python3 -c "import yaml,sys; yaml.safe_load(open('$WORKFLOW_FILE'))" 2>/dev/null; then
    pass_test "deploy.yml is valid YAML"
else
    fail_test "deploy.yml has YAML syntax errors"
    echo ""
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
    exit 1
fi

# Test 3: a concurrency group is declared so deployments are serialised into a
# single "pages" group rather than running fully in parallel.
CONCURRENCY_GROUP=$(python3 -c "
import yaml
data = yaml.safe_load(open('$WORKFLOW_FILE'))
concurrency = data.get('concurrency', {})
if isinstance(concurrency, dict):
    print(concurrency.get('group', ''))
else:
    print(concurrency or '')
" 2>/dev/null)

if [ -n "$CONCURRENCY_GROUP" ]; then
    pass_test "deploy job declares a concurrency group ('$CONCURRENCY_GROUP')"
else
    fail_test "deploy job does not declare a concurrency group"
fi

# Test 4: cancel-in-progress is true so a newer deploy supersedes an older
# in-flight one — the fix for the "Deployment failed, try again later." race.
CANCEL_IN_PROGRESS=$(python3 -c "
import yaml
data = yaml.safe_load(open('$WORKFLOW_FILE'))
concurrency = data.get('concurrency', {})
val = concurrency.get('cancel-in-progress', None) if isinstance(concurrency, dict) else None
# Normalise Python bool to a lowercase string.
print(str(val).lower())
" 2>/dev/null)

if [ "$CANCEL_IN_PROGRESS" = "true" ]; then
    pass_test "deploy concurrency sets cancel-in-progress: true (prevents Pages deploy race)"
else
    fail_test "deploy concurrency cancel-in-progress must be true, got: '$CANCEL_IN_PROGRESS'"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
