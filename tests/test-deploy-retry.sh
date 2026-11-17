#!/bin/bash
# Test for Issue #151: GitHub Pages deploys intermittently fail when frequent
# health pushes overlap.
#
# Root cause: the health monitor pushes docs/** to Develop every few minutes,
# so deploy runs contend on the Pages backend and transiently fail with
# "Deployment failed, try again later." Issue #148 added
# `cancel-in-progress: true`, which reduced but did not eliminate the failures.
#
# Fix: retry the `actions/deploy-pages` step in-run with backoff so transient
# contention is absorbed. Only a genuine, persistent error (retry budget
# exhausted) may fail the run and notify. The retry preserves the github-pages
# environment URL output (`steps.deployment.outputs.page_url`), keeps
# deploy-per-push, and does not change the #148 cancel-in-progress behaviour.
#
# The test parses the workflow YAML with a real parser and asserts on the
# resulting step structure rather than grepping raw text.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_FILE="$SCRIPT_DIR/../.github/workflows/deploy.yml"

echo "Testing Issue #151: deploy.yml in-run retry with backoff"
echo "========================================================"
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

# Extract, once, a structured view of every step in the deploy job as
# newline-delimited records: "<index>|<uses>|<id>|<continue_on_error>|<has_if>|<if_expr>"
STEP_RECORDS=$(python3 -c "
import yaml
data = yaml.safe_load(open('$WORKFLOW_FILE'))
steps = data.get('jobs', {}).get('deploy', {}).get('steps', []) or []
for i, s in enumerate(steps):
    uses = str(s.get('uses', ''))
    sid = str(s.get('id', ''))
    coe = str(s.get('continue-on-error', '')).lower()
    ifexpr = str(s.get('if', ''))
    has_if = 'yes' if 'if' in s else 'no'
    # Collapse pipes/newlines out of the if-expression so records stay 1 line.
    ifexpr = ifexpr.replace('|', ' ').replace('\n', ' ')
    print('%d|%s|%s|%s|%s|%s' % (i, uses, sid, coe, has_if, ifexpr))
" 2>/dev/null)

# Deploy attempts are steps that use actions/deploy-pages.
DEPLOY_RECORDS=$(echo "$STEP_RECORDS" | awk -F'|' '$2 ~ /actions\/deploy-pages@/')
DEPLOY_COUNT=$(echo "$DEPLOY_RECORDS" | grep -c . || true)

# Test 3: there are multiple (>= 3) deploy attempts — the retry budget.
if [ "$DEPLOY_COUNT" -ge 3 ]; then
    pass_test "deploy job retries actions/deploy-pages in-run ($DEPLOY_COUNT attempts)"
else
    fail_test "expected >= 3 actions/deploy-pages attempts for retry, got $DEPLOY_COUNT"
fi

# Test 4: every deploy attempt except the last sets continue-on-error: true, so
# a transient failure does not fail the run — it just triggers the next attempt.
# All deploy attempts except the last (portable: sed '$d' drops the last line).
NON_FINAL=$(echo "$DEPLOY_RECORDS" | sed '$d')
NON_FINAL_BAD=""
if [ -n "$NON_FINAL" ]; then
    while IFS='|' read -r idx uses sid coe has_if ifexpr; do
        [ -z "$uses" ] && continue
        if [ "$coe" != "true" ]; then
            NON_FINAL_BAD+="step $idx (id='$sid') continue-on-error='$coe'"$'\n'
        fi
    done <<< "$NON_FINAL"
fi
if [ -z "$NON_FINAL_BAD" ]; then
    pass_test "every non-final deploy attempt sets continue-on-error: true (absorbs transient failure)"
else
    fail_test "non-final deploy attempts missing continue-on-error: true:"
    echo "$NON_FINAL_BAD" | sed 's/^/    /'
fi

# Test 5: the final deploy attempt does NOT swallow errors (no
# continue-on-error: true), so an exhausted retry budget is a genuine error
# that fails the run and notifies, per the acceptance bar.
FINAL_RECORD=$(echo "$DEPLOY_RECORDS" | tail -n 1)
FINAL_COE=$(echo "$FINAL_RECORD" | awk -F'|' '{print $4}')
FINAL_ID=$(echo "$FINAL_RECORD" | awk -F'|' '{print $3}')
if [ "$FINAL_COE" != "true" ]; then
    pass_test "final deploy attempt fails the run on persistent error (continue-on-error='$FINAL_COE')"
else
    fail_test "final deploy attempt must not set continue-on-error: true (got '$FINAL_COE')"
fi

# Test 6: the final deploy attempt keeps id 'deployment' so the github-pages
# environment URL output (steps.deployment.outputs.page_url) is preserved.
if [ "$FINAL_ID" = "deployment" ]; then
    pass_test "final deploy attempt keeps id 'deployment' (preserves page_url output)"
else
    fail_test "final deploy attempt id must be 'deployment', got '$FINAL_ID'"
fi

# Test 7: each retry attempt (every deploy attempt after the first) is guarded
# by an `if:` that only runs when a previous attempt failed, so we do not
# deploy repeatedly on success — retries happen only on failure.
RETRY_ATTEMPTS=$(echo "$DEPLOY_RECORDS" | tail -n +2)
RETRY_BAD=""
if [ -n "$RETRY_ATTEMPTS" ]; then
    while IFS='|' read -r idx uses sid coe has_if ifexpr; do
        [ -z "$uses" ] && continue
        if [ "$has_if" != "yes" ] || ! echo "$ifexpr" | grep -q "failure"; then
            RETRY_BAD+="step $idx (id='$sid') if='$ifexpr'"$'\n'
        fi
    done <<< "$RETRY_ATTEMPTS"
fi
if [ -z "$RETRY_BAD" ]; then
    pass_test "each retry attempt is guarded by an outcome=='failure' condition"
else
    fail_test "retry attempts not guarded by a previous-failure condition:"
    echo "$RETRY_BAD" | sed 's/^/    /'
fi

# Test 8: there is at least one backoff step (sleep) between attempts, guarded
# by a previous-failure condition — retries wait before hammering the backend.
BACKOFF_STEPS=$(python3 -c "
import yaml
data = yaml.safe_load(open('$WORKFLOW_FILE'))
steps = data.get('jobs', {}).get('deploy', {}).get('steps', []) or []
count = 0
for s in steps:
    run = str(s.get('run', ''))
    ifexpr = str(s.get('if', ''))
    if 'sleep' in run and 'failure' in ifexpr:
        count += 1
print(count)
" 2>/dev/null)
if [ "${BACKOFF_STEPS:-0}" -ge 1 ]; then
    pass_test "retry uses backoff sleep step(s) guarded by failure ($BACKOFF_STEPS found)"
else
    fail_test "expected at least one failure-guarded backoff (sleep) step, found ${BACKOFF_STEPS:-0}"
fi

# Test 9: backoff is progressive (exponential-ish) — the later backoff waits at
# least as long as the earlier one, so contention gets more time to clear.
SLEEP_SECONDS=$(python3 -c "
import re, yaml
data = yaml.safe_load(open('$WORKFLOW_FILE'))
steps = data.get('jobs', {}).get('deploy', {}).get('steps', []) or []
vals = []
for s in steps:
    run = str(s.get('run', ''))
    m = re.search(r'sleep\s+(\d+)', run)
    if m:
        vals.append(int(m.group(1)))
print(' '.join(str(v) for v in vals))
" 2>/dev/null)
# shellcheck disable=SC2206
SLEEP_ARR=($SLEEP_SECONDS)
PROGRESSIVE="yes"
if [ "${#SLEEP_ARR[@]}" -ge 2 ]; then
    for ((i=1; i<${#SLEEP_ARR[@]}; i++)); do
        prev=${SLEEP_ARR[$((i-1))]}
        cur=${SLEEP_ARR[$i]}
        if [ "$cur" -lt "$prev" ]; then
            PROGRESSIVE="no"
        fi
    done
fi
if [ "$PROGRESSIVE" = "yes" ] && [ "${#SLEEP_ARR[@]}" -ge 1 ]; then
    pass_test "backoff waits are non-decreasing (${SLEEP_SECONDS:-none} seconds)"
else
    fail_test "backoff waits must be non-decreasing/progressive (got: '${SLEEP_SECONDS:-none}')"
fi

# Test 10: the github-pages environment URL still resolves the deployment
# page_url (preserved output), tolerating a fallback chain across attempts.
ENV_URL=$(python3 -c "
import yaml
data = yaml.safe_load(open('$WORKFLOW_FILE'))
env = data.get('jobs', {}).get('deploy', {}).get('environment', {})
print(env.get('url', '') if isinstance(env, dict) else '')
" 2>/dev/null)
if echo "$ENV_URL" | grep -q 'steps.deployment.outputs.page_url'; then
    pass_test "environment url preserves steps.deployment.outputs.page_url"
else
    fail_test "environment url must reference steps.deployment.outputs.page_url (got: '$ENV_URL')"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
