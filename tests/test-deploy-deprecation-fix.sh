#!/bin/bash
# Test for Issue #146: fix the Node punycode DEP0040 deprecation warning and
# harden the GitHub Pages deployment.
#
# The deprecation warning originates inside the GitHub-provided
# actions/deploy-pages action (external dependency, already pinned to the
# latest v5.0.0), so it cannot be patched here. We silence it at the Node
# runtime with `--no-deprecation` via NODE_OPTIONS, and we add the canonical
# `environment: github-pages` declaration recommended by GitHub for the deploy
# action to make deployments more observable/reliable.
#
# The test parses the workflow YAML with a real parser and asserts on the
# resulting structure rather than grepping raw text.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_FILE="$SCRIPT_DIR/../.github/workflows/deploy.yml"

echo "Testing Issue #146: deploy.yml deprecation suppression"
echo "======================================================"
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

# Test 3: the deploy job sets NODE_OPTIONS to suppress deprecation warnings.
# Assert on the parsed YAML structure: jobs.deploy.env.NODE_OPTIONS must
# request --no-deprecation (or the broader --no-warnings).
NODE_OPTIONS_VALUE=$(python3 -c "
import yaml, sys
data = yaml.safe_load(open('$WORKFLOW_FILE'))
job = data.get('jobs', {}).get('deploy', {})
env = job.get('env', {}) or {}
print(env.get('NODE_OPTIONS', ''))
" 2>/dev/null)

if echo "$NODE_OPTIONS_VALUE" | grep -qE '\-\-no-deprecation|\-\-no-warnings'; then
    pass_test "deploy job sets NODE_OPTIONS to suppress deprecation warnings ('$NODE_OPTIONS_VALUE')"
else
    fail_test "deploy job does not set NODE_OPTIONS=--no-deprecation (got: '$NODE_OPTIONS_VALUE')"
fi

# Test 4: the deploy job declares the canonical github-pages environment.
ENV_NAME=$(python3 -c "
import yaml, sys
data = yaml.safe_load(open('$WORKFLOW_FILE'))
job = data.get('jobs', {}).get('deploy', {})
environment = job.get('environment', {})
if isinstance(environment, dict):
    print(environment.get('name', ''))
else:
    print(environment or '')
" 2>/dev/null)

if [ "$ENV_NAME" = "github-pages" ]; then
    pass_test "deploy job declares environment name 'github-pages'"
else
    fail_test "deploy job does not declare environment 'github-pages' (got: '$ENV_NAME')"
fi

# Test 5: the deploy step still exposes the page_url output via the
# environment url so the deployment remains observable.
ENV_URL=$(python3 -c "
import yaml, sys
data = yaml.safe_load(open('$WORKFLOW_FILE'))
job = data.get('jobs', {}).get('deploy', {})
environment = job.get('environment', {})
if isinstance(environment, dict):
    print(environment.get('url', ''))
else:
    print('')
" 2>/dev/null)

if echo "$ENV_URL" | grep -q 'steps.deployment.outputs.page_url'; then
    pass_test "deploy environment url references steps.deployment.outputs.page_url"
else
    fail_test "deploy environment url does not reference the deployment page_url (got: '$ENV_URL')"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
