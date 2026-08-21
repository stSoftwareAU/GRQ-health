#!/bin/bash
# Extract pure functions from dashboard.js for unit testing
# Pure functions live between the THRESHOLDS constant and the first DOM-aware
# helper (createHostCard). The end of the pure region is detected at runtime so
# adding new helpers (e.g. Issue #77's getRepoFailureLogUrl) does not require
# manually re-computing line numbers.
# Usage: source this file, then call run_js_test 'your JS test code'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_JS="$SCRIPT_DIR/../docs/dashboard.js"
# Prefer the per-user install, fall back to whatever is on PATH (CI containers
# install deno system-wide). A missing deno must fail loud: an unrunnable
# harness that returns no output would otherwise read as every test passing.
DENO="$HOME/.deno/bin/deno"
if [ ! -x "$DENO" ]; then
    DENO="$(command -v deno || true)"
fi

# Extract pure functions from dashboard.js (everything from the THRESHOLDS
# constant up to — but not including — the first DOM-aware helper).
extract_pure_functions() {
    # Find the line numbers that mark the start/end of the pure section.
    local start_line end_line
    start_line=$(grep -n '^const THRESHOLDS' "$DASHBOARD_JS" | head -1 | cut -d: -f1)
    end_line=$(grep -n '^function createHostCard' "$DASHBOARD_JS" | head -1 | cut -d: -f1)
    if [ -z "$start_line" ] || [ -z "$end_line" ]; then
        # Fall back to a conservative fixed range if the markers move.
        start_line=29
        end_line=900
    fi
    # end_line is exclusive — stop on the line before createHostCard.
    end_line=$((end_line - 1))
    sed -n "${start_line},${end_line}p" "$DASHBOARD_JS"
}

# Run a JS test using deno
# The test code is appended after the pure functions
# Test code should print TEST_RESULT:<name>:<PASS|FAIL>:<detail>
run_js_test() {
    local test_code="$1"
    local functions
    if [ -z "$DENO" ] || [ ! -x "$DENO" ]; then
        echo "ERROR: deno not found (looked in \$HOME/.deno/bin and on PATH)" >&2
        return 1
    fi
    functions="$(extract_pure_functions)"

    echo "${functions}
${test_code}" | "$DENO" run -
}
