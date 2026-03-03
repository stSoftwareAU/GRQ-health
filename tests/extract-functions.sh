#!/bin/bash
# Extract pure functions from dashboard.js for unit testing
# Pure functions are lines 27-721 (no DOM dependencies)
# Usage: source this file, then call run_js_test 'your JS test code'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_JS="$SCRIPT_DIR/../docs/dashboard.js"
DENO="$HOME/.deno/bin/deno"

# Extract pure functions (lines 29-723) from dashboard.js
extract_pure_functions() {
    sed -n '29,723p' "$DASHBOARD_JS"
}

# Run a JS test using deno
# The test code is appended after the pure functions
# Test code should print TEST_RESULT:<name>:<PASS|FAIL>:<detail>
run_js_test() {
    local test_code="$1"
    local functions
    functions="$(extract_pure_functions)"

    echo "${functions}
${test_code}" | "$DENO" run -
}
