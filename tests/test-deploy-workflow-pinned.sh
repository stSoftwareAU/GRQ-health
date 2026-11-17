#!/bin/bash
# Test for Issue #93: Pin GitHub Actions in deploy.yml to 40-char commit SHAs.
# Verifies the deploy workflow file pins every `uses:` reference to a
# 40-character commit SHA and carries a trailing `# vX.Y.Z` version comment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_FILE="$SCRIPT_DIR/../.github/workflows/deploy.yml"

echo "Testing Issue #93: deploy.yml SHA pinning"
echo "========================================="
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
fi

# Test 3: every `uses:` reference is pinned to a 40-char commit SHA, not a tag
UNPINNED=$(grep -E '^\s*-?\s*uses:\s*' "$WORKFLOW_FILE" | grep -vE '@[0-9a-f]{40}(\s|$)' || true)
if [ -z "$UNPINNED" ]; then
    pass_test "All uses: references are pinned to 40-char commit SHAs"
else
    fail_test "Unpinned actions found:"
    echo "$UNPINNED" | sed 's/^/    /'
fi

# Test 4: every pinned `uses:` line carries a trailing `# vX.Y.Z` version comment
USES_LINES=$(grep -E '^\s*-?\s*uses:\s*\S+@[0-9a-f]{40}' "$WORKFLOW_FILE" || true)
MISSING_VERSION=""
if [ -n "$USES_LINES" ]; then
    while IFS= read -r line; do
        # Require a `# vX.Y[.Z]` style trailing comment after the SHA
        if ! echo "$line" | grep -qE '@[0-9a-f]{40}\s+#\s*v[0-9]+(\.[0-9]+){1,2}'; then
            MISSING_VERSION+="$line"$'\n'
        fi
    done <<< "$USES_LINES"
fi
if [ -z "$MISSING_VERSION" ]; then
    pass_test "Every pinned uses: line carries a trailing # vX.Y.Z comment"
else
    fail_test "Pinned uses: lines missing # vX.Y.Z trailing comment:"
    echo "$MISSING_VERSION" | sed 's/^/    /'
fi

# Test 5: no third-party action uses a moving tag (e.g. @main, @master, @vN)
MOVING_TAG=$(grep -E '^\s*-?\s*uses:\s*\S+@(main|master|v[0-9]+)\s*$' "$WORKFLOW_FILE" || true)
if [ -z "$MOVING_TAG" ]; then
    pass_test "No actions reference moving tags (@main, @master, @vN)"
else
    fail_test "Actions referenced via moving tags found:"
    echo "$MOVING_TAG" | sed 's/^/    /'
fi

# Test 6: a comment block in deploy.yml documents the SHA pin convention
COMMENT_LINES=$(grep -E '^\s*#' "$WORKFLOW_FILE" || true)
if echo "$COMMENT_LINES" | grep -qiE 'pin' && echo "$COMMENT_LINES" | grep -qiE 'sha'; then
    pass_test "Pin convention is documented via comments in deploy.yml"
else
    fail_test "deploy.yml does not document the SHA pin convention via comments"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
