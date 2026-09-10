#!/bin/bash
# Test for Issue #205: SCR-SEC-ALERTING — verifiable alerting path for
# security-relevant CI failures.
#
# The alerting path this repo commits to is the escalation document
# SECURITY.md. This test parses that document and asserts it actually
# names the scans it covers, who triages a failed scan, and the route a
# security signal takes to a human — so the path stays verifiable rather
# than becoming a heading with nothing under it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_FILE="$SCRIPT_DIR/../SECURITY.md"

echo "Testing Issue #205: SECURITY.md escalation path"
echo "==============================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Test 1: the policy exists at the repo root, where GitHub reads it from.
if [ -f "$POLICY_FILE" ]; then
    pass_test "SECURITY.md exists at the repository root"
else
    fail_test "SECURITY.md is missing from the repository root"
    echo ""
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
    exit 1
fi

# Reads SECURITY.md, splits it into { heading: body } sections, and runs
# the supplied python snippet against that map.
run_policy() {
    local code="$1"
    python3 - "$POLICY_FILE" <<PYEOF
import re, sys

text = open(sys.argv[1], encoding="utf-8").read()
sections = {}
heading = None
for line in text.splitlines():
    m = re.match(r'^(#{1,6})\s+(.*?)\s*\$', line)
    if m:
        heading = m.group(2)
        sections[heading] = []
    elif heading is not None:
        sections[heading].append(line)
sections = {k: "\n".join(v).strip() for k, v in sections.items()}

def section(pattern):
    """Body of the first heading matching pattern, or '' when absent."""
    for k, v in sections.items():
        if re.search(pattern, k, re.I):
            return v
    return ""

$code
PYEOF
}

# Test 2: a section covers a failing security scan in CI.
CI_BODY=$(run_policy "print(section(r'(scan|ci).*fail|fail.*(scan|ci)'))")
if [ -n "$CI_BODY" ]; then
    pass_test "A section covers failing security scans in CI"
else
    fail_test "No section covers what happens when a security scan fails in CI"
fi

# Test 3: that section names both committed scans, so neither is orphaned.
for scan in gitleaks semgrep; do
    if printf '%s' "$CI_BODY" | grep -qi -- "$scan"; then
        pass_test "Failed-scan section names the $scan scan"
    else
        fail_test "Failed-scan section does not name the $scan scan"
    fi
done

# Test 4: the failed-scan section names a human owner (a GitHub handle or
# an org), not just "someone".
if printf '%s' "$CI_BODY" | grep -qE '@[A-Za-z0-9][-A-Za-z0-9]*'; then
    pass_test "Failed-scan section names a triage owner by handle"
else
    fail_test "Failed-scan section names no triage owner (expected an @handle)"
fi

# Test 5: it gives an actionable escalation route, not just an owner.
if printf '%s' "$CI_BODY" | grep -qiE 'issue|advisor|label'; then
    pass_test "Failed-scan section gives an escalation route"
else
    fail_test "Failed-scan section gives no escalation route (issue/advisory/label)"
fi

# Test 6: a vulnerability-reporting section exists with a private route.
REPORT_BODY=$(run_policy "print(section(r'report'))")
if printf '%s' "$REPORT_BODY" | grep -qiE 'advisor|private'; then
    pass_test "Reporting section gives a private disclosure route"
else
    fail_test "Reporting section gives no private disclosure route"
fi

# Test 7: a response-time commitment turns the route into an alert with a
# deadline rather than an open-ended promise.
if run_policy "
import re
body = section(r'report') + '\n' + section(r'(scan|ci).*fail|fail.*(scan|ci)')
print('yes' if re.search(r'\d+\s*(business\s+)?(hour|day|week)', body, re.I) else 'no')
" | grep -q yes; then
    pass_test "A response-time commitment is stated"
else
    fail_test "No response-time commitment is stated"
fi

# Test 8: supported-versions section, so a reporter knows what is in scope.
SUPPORTED=$(run_policy "print(section(r'support|scope|version'))")
if [ -n "$SUPPORTED" ]; then
    pass_test "A supported-versions/scope section is present"
else
    fail_test "No supported-versions/scope section is present"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
