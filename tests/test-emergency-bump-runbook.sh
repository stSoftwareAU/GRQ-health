#!/bin/bash
# Test for Issue #206: SCR-RUNBOOK — a documented emergency-bump procedure.
#
# SECURITY.md already carries the disclosure contact (Issue #205). This
# test covers the other half of the runbook: the emergency override path
# used to ship an urgent CVE bump ahead of the normal quarantine window.
#
# The assertions deliberately run in two directions:
#   1. SECURITY.md documents the procedure (a flag, a value, a human
#      gate, and a restore step), and
#   2. the flag it names is genuinely accepted by the real bump-deps.sh.
#
# Direction 2 is what stops the runbook drifting into fiction: if the
# flag is ever renamed or dropped, this test fails rather than leaving
# operators following a procedure that no longer works.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POLICY_FILE="$REPO_ROOT/SECURITY.md"
BUMP_SCRIPT="$REPO_ROOT/bump-deps.sh"

echo "Testing Issue #206: emergency-bump runbook"
echo "=========================================="
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
fenced = False
for line in text.splitlines():
    # A '#' inside a fenced block is a shell comment, not a heading.
    if re.match(r'^\s*(?:' + chr(96) * 3 + '|~~~)', line):
        fenced = not fenced
    m = None if fenced else re.match(r'^(#{1,6})\s+(.*?)\s*\$', line)
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

# Test 2: a section covers the emergency/urgent bump path.
BUMP_BODY=$(run_policy "print(section(r'emergency|urgent|expedit'))")
if [ -n "$BUMP_BODY" ]; then
    pass_test "A section covers the emergency bump procedure"
else
    fail_test "No section covers an emergency/urgent bump procedure"
fi

# Test 3: it names the script an operator actually runs.
if printf '%s' "$BUMP_BODY" | grep -q -- 'bump-deps.sh'; then
    pass_test "Emergency section names bump-deps.sh"
else
    fail_test "Emergency section does not name bump-deps.sh"
fi

# Test 4: it names the override flag, extracted rather than assumed so
# tests 6 and 7 check the real script against what the doc claims.
DOC_FLAG=$(printf '%s' "$BUMP_BODY" | grep -oE -- '--[a-z][-a-z]*hours' | head -1 || true)
if [ -n "$DOC_FLAG" ]; then
    pass_test "Emergency section names an override flag ($DOC_FLAG)"
else
    fail_test "Emergency section names no quarantine-override flag"
fi

# Test 5: it gives a concrete value, so the procedure is runnable rather
# than a gesture at one.
if printf '%s' "$BUMP_BODY" | grep -qE -- '--[a-z][-a-z]*hours[ =]+[0-9]+'; then
    pass_test "Emergency section shows the flag with a concrete value"
else
    fail_test "Emergency section shows no concrete value for the override"
fi

# Test 6: the documented flag is genuinely accepted by bump-deps.sh.
# Runs the real script; --help parses args without touching the network.
if [ -n "$DOC_FLAG" ]; then
    if "$BUMP_SCRIPT" --help < /dev/null 2>&1 | grep -q -- "$DOC_FLAG"; then
        pass_test "bump-deps.sh --help documents the flag SECURITY.md names"
    else
        fail_test "bump-deps.sh does not document '$DOC_FLAG' (runbook has drifted)"
    fi
else
    fail_test "Cannot verify the override flag against bump-deps.sh: none documented"
fi

# Test 7: the real script validates that flag's argument, so a fat-finger
# during an incident fails loudly instead of silently widening the window.
if [ -n "$DOC_FLAG" ]; then
    if "$BUMP_SCRIPT" "$DOC_FLAG" not-a-number < /dev/null >/dev/null 2>&1; then
        fail_test "bump-deps.sh accepted a non-numeric '$DOC_FLAG' value"
    else
        pass_test "bump-deps.sh rejects a non-numeric '$DOC_FLAG' value"
    fi
fi

# Test 8: the procedure is gated on a human and leaves a record, rather
# than letting anyone bypass quarantine unrecorded.
if printf '%s' "$BUMP_BODY" | grep -qiE 'advisor|issue|@[A-Za-z0-9][-A-Za-z0-9]*'; then
    pass_test "Emergency section names a human gate or record"
else
    fail_test "Emergency section names no human gate or record"
fi

# Test 9: the override is per-run — the default window must be restored,
# otherwise an incident permanently disables quarantine.
if printf '%s' "$BUMP_BODY" | grep -qiE 'restore|revert|per-run|single run|this run|not.*permanent|do not commit'; then
    pass_test "Emergency section states the override is per-run only"
else
    fail_test "Emergency section does not state the override is per-run only"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
