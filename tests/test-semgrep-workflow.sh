#!/bin/bash
# Test for Issue #90: Semgrep SAST Scanning workflow, extended by Issue #190.
# Verifies that .github/workflows/semgrep.yml exists, is valid YAML,
# and is wired up correctly (PR trigger, read-only permissions, container,
# semgrep ci step, SHA-pinned actions) — and that SEMGREP_APP_TOKEN is scoped
# away from every job a pull request can reach (issue #190).

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

# --- Issue #190: token scoping -------------------------------------------
# Test 9 previously asserted the opposite of what follows: it required the
# `semgrep ci` step of the PR-gate job to expose SEMGREP_APP_TOKEN. Issue #190
# reversed that requirement — a job triggered by `pull_request` checks out and
# scans PR-controlled code, so any secret in its environment is readable by
# whatever that code causes the job to execute. The assertions below therefore
# replace the old test 9: the token must be absent from every job a pull
# request can reach, and present only on a trusted, non-PR path.

# Shared model: which jobs can a `pull_request` event actually run? A job is
# PR-reachable when the workflow triggers on pull_request and the job's `if`
# does not exclude the event. An `if` expression this matcher cannot model is
# treated as reachable, so an unmodelled guard fails loudly rather than
# silently exempting a job from the token check.
PR_MODEL='
import re

def if_allows_pr(expr):
    if expr is None:
        return True
    e = str(expr).strip()
    m = re.fullmatch(r"\$\{\{(.*)\}\}", e, re.S)
    if m:
        e = m.group(1).strip()
    e = e.replace("github.event_name", "\x27pull_request\x27")
    e = e.replace("&&", " and ").replace("||", " or ")
    e = re.sub(r"(?<![=!<>])!(?![=])", " not ", e)
    if not re.fullmatch(r"[\sA-Za-z0-9_\x27\"()=!.]*", e):
        return True
    try:
        return bool(eval(e, {"__builtins__": {}}, {}))
    except Exception:
        return True

def jobs_reachable_by_pr():
    if not (isinstance(on, dict) and "pull_request" in on):
        return []
    return [(jid, job) for jid, job in (wf.get("jobs") or {}).items()
            if if_allows_pr((job or {}).get("if"))]

def mentions_token(node):
    return "SEMGREP_APP_TOKEN" in yaml.safe_dump(node, default_flow_style=False)
'

# Test 9: no job a pull request can reach exposes SEMGREP_APP_TOKEN, at any
# level (workflow env, job env, container env, step env, or the command line).
PR_TOKEN_JOBS=$(run_yaml "$PR_MODEL
leaky = []
if mentions_token(wf.get('env') or {}):
    leaky.append('<workflow-level env>')
leaky += [jid for jid, job in jobs_reachable_by_pr() if mentions_token(job or {})]
print(','.join(leaky))
")
if [ -z "$PR_TOKEN_JOBS" ]; then
    pass_test "No pull_request-reachable job exposes SEMGREP_APP_TOKEN"
else
    fail_test "SEMGREP_APP_TOKEN is exposed to PR-controlled code in: $PR_TOKEN_JOBS"
fi

# Test 10: the PR gate still scans — dropping the token must not have dropped
# the scan with it.
PR_SCAN_JOBS=$(run_yaml "$PR_MODEL
ok = []
for jid, job in jobs_reachable_by_pr():
    for s in ((job or {}).get('steps') or []):
        run = ' '.join(str(s.get('run', '')).split())
        if 'semgrep ci' in run and '--config' in run:
            ok.append(jid)
            break
print(','.join(ok))
")
if [ -n "$PR_SCAN_JOBS" ]; then
    pass_test "A pull_request-reachable job still runs 'semgrep ci --config' ($PR_SCAN_JOBS)"
else
    fail_test "No pull_request-reachable job runs 'semgrep ci --config' — the PR gate scans nothing"
fi

# Test 11: the authenticated upload survives, on a trusted path only. The job
# carrying the token must exist and must not be reachable from pull_request.
UPLOAD_JOBS=$(run_yaml "$PR_MODEL
pr_reachable = {jid for jid, _ in jobs_reachable_by_pr()}
print(','.join(jid for jid, job in (wf.get('jobs') or {}).items()
                if mentions_token(job or {}) and jid not in pr_reachable))
")
if [ -n "$UPLOAD_JOBS" ]; then
    pass_test "SEMGREP_APP_TOKEN is scoped to trusted, non-PR job(s): $UPLOAD_JOBS"
else
    fail_test "No non-PR job carries SEMGREP_APP_TOKEN — the authenticated upload is gone"
fi

# Test 12: a trigger exists that can actually run the trusted upload job
# (push, schedule or workflow_dispatch) — a gated job with no trigger to fire
# it never runs.
HAS_TRUSTED_TRIGGER=$(run_yaml "
triggers = set(on.keys()) if isinstance(on, dict) else ({on} if isinstance(on, str) else set())
print('yes' if triggers & {'push', 'schedule', 'workflow_dispatch', 'workflow_run'} else 'no')
")
if [ "$HAS_TRUSTED_TRIGGER" = "yes" ]; then
    pass_test "Workflow declares a trusted (non-pull_request) trigger for the upload job"
else
    fail_test "Workflow has no push/schedule/workflow_dispatch trigger to run the upload job"
fi

# Test 13: every `uses:` reference is pinned to a 40-char commit SHA, not a tag
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
