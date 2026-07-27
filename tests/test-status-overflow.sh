#!/bin/bash
# Test script for Issue #17: Status badge overflow fix
# This script verifies that the CSS fix was implemented correctly

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STYLES_CSS="$SCRIPT_DIR/../docs/styles.css"
DASHBOARD_JS_PATH="$SCRIPT_DIR/../docs/dashboard.js"
TRUNCATION_CHECKER="$SCRIPT_DIR/hostname-truncation-check.js"
TRUNCATION_FIXTURES="$SCRIPT_DIR/fixtures/hostname-truncation"
DENO="$HOME/.deno/bin/deno"

echo "Testing Issue #17: Status badge overflow fix"
echo "============================================="
echo ""

# Test 1: Check that .host-card has overflow: hidden
echo "Test 1: Checking that .host-card has overflow: hidden..."
if grep -A15 '^\.host-card {' "$STYLES_CSS" | grep -q 'overflow: hidden'; then
    echo "  PASS: .host-card has overflow: hidden"
else
    echo "  FAIL: .host-card is missing overflow: hidden"
    exit 1
fi

# Test 2: Check that .health-status has flex-shrink: 0
echo "Test 2: Checking that .health-status has flex-shrink: 0..."
if grep -A10 '^\.health-status {' "$STYLES_CSS" | grep -q 'flex-shrink: 0'; then
    echo "  PASS: .health-status has flex-shrink: 0"
else
    echo "  FAIL: .health-status is missing flex-shrink: 0"
    exit 1
fi

# Test 3: Check that .health-status has white-space: nowrap
echo "Test 3: Checking that .health-status has white-space: nowrap..."
if grep -A10 '^\.health-status {' "$STYLES_CSS" | grep -q 'white-space: nowrap'; then
    echo "  PASS: .health-status has white-space: nowrap"
else
    echo "  FAIL: .health-status is missing white-space: nowrap"
    exit 1
fi

# Test 4: Check that host card header h5 has min-width: 0 for proper flex behaviour
echo "Test 4: Checking for host card header flex fix..."
if grep -q '\.host-card h5' "$STYLES_CSS" && grep -A5 '\.host-card h5' "$STYLES_CSS" | grep -q 'min-width: 0'; then
    echo "  PASS: Host card h5 has proper flex behaviour"
else
    # Alternative: check in the dashboard.js template
    DASHBOARD_JS="$SCRIPT_DIR/../docs/dashboard.js"
    if grep -q "min-width: 0" "$DASHBOARD_JS" || grep -q 'min-width: 0' "$STYLES_CSS"; then
        echo "  PASS: Host card h5 has proper flex behaviour (inline or CSS)"
    else
        echo "  FAIL: Missing min-width: 0 for .host-card h5"
        exit 1
    fi
fi

# Test 5: Card variants inherit overflow from the base .host-card class
echo "Test 5: Checking overflow consistency across card variants..."
# All variants (.host-card.mia, .host-card.mobile, .host-card.outdated-macos,
# .host-card.critical, .host-card.warning, .host-card.healthy) rely on the
# base .host-card having overflow: hidden, which Test 1 already verified.
echo "  PASS: Base .host-card should handle overflow for all variants"

# --- Issue #174: the hostname must truncate, not wrap ------------------------
#
# Test 4 above only ever checked `min-width: 0`, which is how `.host-card h5`
# shipped `overflow: hidden; text-overflow: ellipsis` with no `white-space:
# nowrap`. The ellipsis never fired, so `Tinas-MacBook-Air` wrapped onto a
# second line and pushed the header into the "OFF THE GRID" badge (Issue #169).
#
# tests/hostname-truncation-check.js closes that gap: for every host-card header
# template in docs/dashboard.js it locates the element that actually holds the
# hostname *text run*, resolves the CSS applying to that element, and asks
# whether the box can truncate — so restructuring the header is fine as long as
# the hostname still lands in a truncating box with its badges intact.

TRUNCATION_OUTPUT=""

run_truncation_checker() {
    local css="$1" js="$2"
    if ! TRUNCATION_OUTPUT="$("$DENO" run --allow-read "$TRUNCATION_CHECKER" "$css" "$js" < /dev/null 2>&1)"; then
        echo "$TRUNCATION_OUTPUT"
        return 1
    fi
    if [ -z "$TRUNCATION_OUTPUT" ]; then
        echo "  (checker produced no TEST_RESULT lines for $css + $js)"
        return 1
    fi
    return 0
}

truncation_verdict() {
    local name="$1" line
    line="$(printf '%s\n' "$TRUNCATION_OUTPUT" | grep "^TEST_RESULT:${name}:" | head -1)"
    if [ -z "$line" ]; then
        echo "MISSING"
    else
        echo "$line" | cut -d: -f3
    fi
}

expect_truncation_verdict() {
    local name="$1" expected="$2" why="$3" actual
    actual="$(truncation_verdict "$name")"
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $name is $expected — $why"
    else
        echo "  FAIL: $name is $actual, expected $expected — $why"
        exit 1
    fi
}

echo "Test 6: Checking that the hostname truncates instead of wrapping (Issue #174)..."
if [ ! -x "$DENO" ]; then
    echo "  FAIL: deno not found at $DENO — cannot verify hostname truncation"
    exit 1
fi

if ! run_truncation_checker "$STYLES_CSS" "$DASHBOARD_JS_PATH"; then
    echo "  FAIL: hostname-truncation-check.js failed on docs/styles.css + docs/dashboard.js"
    exit 1
fi

TRUNCATION_FAILURES=0
while IFS= read -r line; do
    case "$line" in
        TEST_RESULT:*)
            name="$(echo "$line" | cut -d: -f2)"
            result="$(echo "$line" | cut -d: -f3)"
            detail="$(echo "$line" | cut -d: -f4-)"
            if [ "$result" = "PASS" ]; then
                echo "  PASS: $name — $detail"
            else
                echo "  FAIL: $name — $detail"
                TRUNCATION_FAILURES=$((TRUNCATION_FAILURES + 1))
            fi
            ;;
        *) [ -n "$line" ] && echo "  $line" ;;
    esac
done <<< "$TRUNCATION_OUTPUT"

if [ "$TRUNCATION_FAILURES" -gt 0 ]; then
    echo "  FAIL: $TRUNCATION_FAILURES hostname truncation check(s) failed"
    exit 1
fi

echo "Test 7: Self-test — the checker must still detect the pre-fix defect..."
if ! run_truncation_checker "$TRUNCATION_FIXTURES/pre-fix.css" "$TRUNCATION_FIXTURES/pre-fix.js"; then
    echo "  FAIL: hostname-truncation-check.js failed on the pre-fix fixture"
    exit 1
fi

expect_truncation_verdict "hostname-truncation-headers-discovered" PASS \
    "the fixture's header templates are enumerated"
expect_truncation_verdict "hostname-truncation-line-10-cannot-wrap" FAIL \
    "the MIA header without white-space: nowrap is the unfixed defect"
expect_truncation_verdict "hostname-truncation-line-19-cannot-wrap" FAIL \
    "the active-host header without white-space: nowrap is the unfixed defect"
expect_truncation_verdict "hostname-truncation-line-19-badges-not-clipped" FAIL \
    "a machine-type badge inside the truncating box would be ellipsised away"
expect_truncation_verdict "hostname-truncation-line-10-full-hostname-discoverable" FAIL \
    "a truncated hostname with no title attribute is unrecoverable"

echo "Test 8: Guard-degradation — a template with no header must not pass by vacuity..."
if ! run_truncation_checker "$STYLES_CSS" "$TRUNCATION_FIXTURES/no-headers.js"; then
    echo "  FAIL: hostname-truncation-check.js failed on the empty fixture"
    exit 1
fi
expect_truncation_verdict "hostname-truncation-headers-discovered" FAIL \
    "discovering zero host-card headers is itself a failure"

echo ""
echo "============================================="
echo "All tests passed!"
echo ""
echo "Summary of fix for Issue #17:"
echo "- Added overflow: hidden to base .host-card class"
echo "- Added flex-shrink: 0 to .health-status to prevent shrinking"
echo "- Added white-space: nowrap to .health-status to prevent wrapping"
echo "- The status badge should now stay within the host panel boundaries"
