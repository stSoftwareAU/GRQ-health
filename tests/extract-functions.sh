#!/bin/bash
# Extract pure (testable) functions from dashboard.js for use in deno-based tests.
#
# This helper extracts standalone functions that do not depend on the DOM,
# so they can be evaluated by deno to run functional tests.
#
# Usage in test scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/extract-functions.sh"
#   # Then use run_js_test "your test code here"

EXTRACT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_JS="$EXTRACT_SCRIPT_DIR/../docs/dashboard.js"

# Find deno on PATH or at known location
find_deno() {
    if command -v deno >/dev/null 2>&1; then
        echo "deno"
    elif [ -x "$HOME/.deno/bin/deno" ]; then
        echo "$HOME/.deno/bin/deno"
    else
        echo ""
    fi
}

# Extract the pure functions from dashboard.js (lines 27-644).
# These include: formatUptime, formatTimestamp, sanitizeUserSlug,
# getUserEntries, getExpectedUsers, getWorstUserHeartbeatTs,
# getUserHeartbeatWarningHours, getStaleUsers, buildStaleUserWarning,
# getIdleWorkerStatus, buildIdleWorkerWarning, getRepoStatus,
# getRepoStats, getHealthStatus.
extract_dashboard_functions() {
    sed -n '27,644p' "$DASHBOARD_JS"
}

# Run a JavaScript test string using the extracted dashboard functions.
# Arg 1: the test JavaScript code as a string.
# Returns: exit code 0 on success, 1 on failure.
# stdout: output from the test code.
run_js_test() {
    local test_code="$1"
    local deno_bin
    deno_bin=$(find_deno)

    if [ -z "$deno_bin" ]; then
        echo "SKIP: deno not found" >&2
        return 0
    fi

    local full_code
    full_code="$(extract_dashboard_functions)
${test_code}"

    echo "$full_code" | "$deno_bin" run --no-prompt -
}
