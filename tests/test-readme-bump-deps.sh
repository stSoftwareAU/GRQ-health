#!/bin/bash
# Test for Issue #96: README documents the auto-bump dependency workflow
# Verifies that README.md contains the Dependency Maintenance section
# covering SHA pinning, bump-deps.sh, the scheduled workflow, and
# quarantine policy.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
README="$REPO_ROOT/README.md"

echo "Testing Issue #96: README auto-bump documentation"
echo "================================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() {
    echo "  PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail_test() {
    echo "  FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Test 1: README has the Dependency Maintenance section
if grep -q "^## Dependency Maintenance" "$README"; then
    pass_test "README contains '## Dependency Maintenance' section"
else
    fail_test "README missing '## Dependency Maintenance' section"
fi

# Test 2: SHA pinning convention is described
if grep -qi "SHA pinning" "$README" && grep -q "40-char" "$README"; then
    pass_test "README explains SHA pinning convention"
else
    fail_test "README missing SHA pinning convention details"
fi

# Test 3: Example uses: line is shown with a 40-char SHA and # vX.Y.Z comment
if grep -qE "uses: [A-Za-z0-9_./-]+@[0-9a-f]{40} +# +v[0-9]+(\.[0-9]+){0,2}" "$README"; then
    pass_test "README shows an example pinned 'uses:' line"
else
    fail_test "README missing example pinned 'uses:' line"
fi

# Test 4: bump-deps.sh script is described with its three flags
if grep -q "bump-deps.sh" "$README" \
   && grep -q -- "--dry-run" "$README" \
   && grep -q -- "--quarantine-hours" "$README" \
   && grep -q -- "--help" "$README"; then
    pass_test "README documents bump-deps.sh and its flags"
else
    fail_test "README missing bump-deps.sh flag documentation"
fi

# Test 5: Local-usage example is present
if grep -q '\./bump-deps.sh --dry-run' "$README"; then
    pass_test "README shows './bump-deps.sh --dry-run' example"
else
    fail_test "README missing './bump-deps.sh --dry-run' usage example"
fi

# Test 6: Scheduled workflow timing is documented
if grep -q "06:00 UTC" "$README" && grep -qi "Monday" "$README"; then
    pass_test "README documents the schedule (Monday 06:00 UTC)"
else
    fail_test "README missing schedule details (Monday 06:00 UTC)"
fi

# Test 7: PR branch and workflow_dispatch are mentioned
if grep -q "chore/bump-deps" "$README" && grep -q "workflow_dispatch" "$README"; then
    pass_test "README documents PR branch and workflow_dispatch"
else
    fail_test "README missing PR branch or workflow_dispatch reference"
fi

# Test 8: Quarantine policy is documented
if grep -q "VIBE_BUMP_QUARANTINE_HOURS" "$README" \
   && grep -q "24" "$README" \
   && grep -q "stSoftwareAU" "$README"; then
    pass_test "README documents the quarantine policy"
else
    fail_test "README missing quarantine policy details"
fi

# Test 9: Audit gate is documented
if grep -qi "audit gate" "$README" && grep -q "quality.sh" "$README"; then
    pass_test "README documents the audit gate"
else
    fail_test "README missing audit gate documentation"
fi

# Test 10: Reviewer responsibilities are listed
if grep -qi "reviewer" "$README"; then
    pass_test "README mentions reviewer responsibilities"
else
    fail_test "README missing reviewer responsibilities section"
fi

# Test 11: Australian English — check only the new Dependency Maintenance
# section to avoid touching unrelated content elsewhere in the README.
SECTION=$(awk '/^## Dependency Maintenance/{flag=1; next} /^## /{flag=0} flag' "$README")
if echo "$SECTION" | grep -qE '\b(behavior|color|favor|organization|center|honor|defense)\b'; then
    fail_test "Dependency Maintenance section uses American spelling"
else
    pass_test "Dependency Maintenance section uses Australian English spelling"
fi

echo ""
echo "================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
