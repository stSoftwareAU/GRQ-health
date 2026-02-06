#!/bin/bash
# Quality check script for GRQ-health
# Runs all tests and checks code quality

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "GRQ Health Quality Check"
echo "========================"
echo ""

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

run_test() {
    local test_name="$1"
    local test_script="$2"

    echo "Running: $test_name"
    echo "---"

    if "$test_script"; then
        echo "Status: PASSED"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo "Status: FAILED"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo ""
}

# Run shell-based tests
if [ -d "$SCRIPT_DIR/tests" ]; then
    for test_file in "$SCRIPT_DIR"/tests/test-*.sh; do
        if [ -f "$test_file" ]; then
            test_name=$(basename "$test_file" .sh)
            run_test "$test_name" "$test_file"
        fi
    done
fi

# Check for JSON syntax errors in index.json
echo "Checking JSON syntax in docs/index.json..."
echo "---"
if [ -f "$SCRIPT_DIR/docs/index.json" ]; then
    if command -v jq >/dev/null 2>&1; then
        if jq . "$SCRIPT_DIR/docs/index.json" > /dev/null 2>&1; then
            echo "Status: PASSED - JSON is valid"
            PASSED_TESTS=$((PASSED_TESTS + 1))
        else
            echo "Status: FAILED - JSON syntax error"
            FAILED_TESTS=$((FAILED_TESTS + 1))
        fi
        TOTAL_TESTS=$((TOTAL_TESTS + 1))
    else
        echo "Status: SKIPPED - jq not installed"
    fi
else
    echo "Status: SKIPPED - docs/index.json not found"
fi
echo ""

# Check for version consistency
echo "Checking version consistency..."
echo "---"
VERSION_RUN_SH=$(grep '^VERSION=' "$SCRIPT_DIR/run.sh" | head -1 | cut -d'"' -f2)
VERSION_DASHBOARD_JS=$(grep '^const VERSION = ' "$SCRIPT_DIR/docs/dashboard.js" | head -1 | sed 's/.*"\(.*\)".*/\1/')

if [ "$VERSION_RUN_SH" = "$VERSION_DASHBOARD_JS" ]; then
    echo "run.sh version: $VERSION_RUN_SH"
    echo "dashboard.js version: $VERSION_DASHBOARD_JS"
    echo "Status: PASSED - Versions match"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    echo "run.sh version: $VERSION_RUN_SH"
    echo "dashboard.js version: $VERSION_DASHBOARD_JS"
    echo "Status: FAILED - Versions do not match"
    echo "Run ./update_version.sh to sync versions"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi
TOTAL_TESTS=$((TOTAL_TESTS + 1))
echo ""

# Summary
echo "========================"
echo "Quality Check Summary"
echo "========================"
echo "Total tests: $TOTAL_TESTS"
echo "Passed: $PASSED_TESTS"
echo "Failed: $FAILED_TESTS"
echo ""

if [ "$FAILED_TESTS" -gt 0 ]; then
    echo "QUALITY CHECK FAILED"
    exit 1
else
    echo "QUALITY CHECK PASSED"
    exit 0
fi
