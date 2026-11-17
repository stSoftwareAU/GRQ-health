#!/bin/bash
# Test for Issue #114: All shell scripts must pass shellcheck at warning severity
# (matches the severity used by .github/workflows/shellcheck.yml).
#
# This is a regression test: when introduced, every script in the repo was
# clean at warning severity. Future PRs that re-introduce common warnings
# (declare-and-assign, unused variables, references-not-assigned, redirection
# without command) will fail this gate before reaching CI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."

echo "Testing Issue #114: shellcheck warning-severity is clean"
echo "========================================================"
echo ""

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "  SKIP: shellcheck not installed locally"
    exit 0
fi

# Collect all shell scripts the CI workflow scans (it scans the whole repo).
# Use a portable (bash 3.2 compatible) approach instead of mapfile.
SHELL_FILES=()
while IFS= read -r f; do
    SHELL_FILES+=("$f")
done < <(find "$REPO_ROOT" \
    -path "$REPO_ROOT/.git" -prune -o \
    -path "$REPO_ROOT/node_modules" -prune -o \
    -type f -name "*.sh" -print | sort)

if [ "${#SHELL_FILES[@]}" -eq 0 ]; then
    echo "  FAIL: no shell scripts found to lint"
    exit 1
fi

echo "Linting ${#SHELL_FILES[@]} shell scripts at severity=warning..."

OUTPUT=$(shellcheck --severity=warning "${SHELL_FILES[@]}" 2>&1 || true)

if [ -z "$OUTPUT" ]; then
    echo "  PASS: all shell scripts are clean at warning severity"
    echo ""
    echo "Results: 1 passed, 0 failed"
    exit 0
fi

echo "  FAIL: shellcheck reported warnings:"
echo "$OUTPUT" | sed 's/^/    /'
echo ""
echo "Results: 0 passed, 1 failed"
exit 1
