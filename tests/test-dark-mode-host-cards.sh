#!/bin/bash
# Test for Issue #172: a WCAG contrast regression guard covering every
# .host-card variant in dark mode.
#
# #161 introduced the dark palette, and #165, #170 and #171 then fixed the same
# fault three times over: a component hardcodes a light background, survives the
# `[data-theme="dark"]` switch, and the dark palette's light text renders on it
# unreadably. Each instance was found by a human looking at a phone screenshot,
# because nothing in the suite covered the class of defect.
#
# tests/dark-mode-card-check.js closes that gap by *enumerating* the
# `.host-card.<variant>` rules in docs/styles.css rather than working from a
# fixed list, resolving the background the dark theme actually applies to each
# one (gradient stop by gradient stop, translucent layers composited over the
# dark page surface) and asserting WCAG 2.1 AA against --card-text and
# --muted-color. A new variant with a light background and no dark override
# fails here without any edit to this test.
#
# Two self-tests keep the guard honest:
#   * tests/fixtures/dark-mode-cards/variants.css has known-good and known-bad
#     variants, so a checker that stopped detecting the defect (gradient stops
#     skipped, alpha treated as opaque, dark override resolution broken) fails.
#   * tests/fixtures/dark-mode-cards/no-cards.css has no variants at all, so a
#     broken enumeration reports zero variants and goes red instead of
#     green-by-vacuity.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STYLES_CSS="$ROOT_DIR/docs/styles.css"
FIXTURES="$SCRIPT_DIR/fixtures/dark-mode-cards"
CHECKER="$SCRIPT_DIR/dark-mode-card-check.js"
DENO="$HOME/.deno/bin/deno"

echo "Testing Issue #172: dark mode host-card contrast sweep"
echo "==========================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0
OUTPUT=""

pass() {
    echo "  PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "  FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Run the checker over a stylesheet, failing loud if it errors out rather than
# treating "no results" as a clean run.
run_checker() {
    local css="$1"
    if ! OUTPUT="$("$DENO" run --allow-read="$css" "$CHECKER" "$css" < /dev/null 2>&1)"; then
        echo "$OUTPUT"
        return 1
    fi
    if [ -z "$OUTPUT" ]; then
        echo "  (checker produced no TEST_RESULT lines for $css)"
        return 1
    fi
    return 0
}

# Verdict recorded for a named result in the last run, or "MISSING".
verdict_of() {
    local name="$1" line
    line="$(printf '%s\n' "$OUTPUT" | grep "^TEST_RESULT:${name}:" | head -1)"
    if [ -z "$line" ]; then
        echo "MISSING"
    else
        echo "$line" | cut -d: -f3
    fi
}

expect_verdict() {
    local name="$1" expected="$2" why="$3" actual detail
    actual="$(verdict_of "$name")"
    detail="$(printf '%s\n' "$OUTPUT" | grep "^TEST_RESULT:${name}:" | head -1 | cut -d: -f4-)"
    if [ "$actual" = "$expected" ]; then
        pass "$name is $expected — $why"
    else
        fail "$name is $actual, expected $expected — $why ${detail:+[$detail]}"
    fi
}

if [ ! -x "$DENO" ]; then
    echo "  FAIL: deno not found at $DENO — cannot verify dark mode colours"
    exit 1
fi

# --- 1. The real stylesheet: every enumerated variant must meet AA -----------

echo "docs/styles.css — every .host-card variant in dark mode:"
if ! run_checker "$STYLES_CSS"; then
    echo "  FAIL: dark-mode-card-check.js failed on docs/styles.css"
    exit 1
fi

while IFS= read -r line; do
    case "$line" in
        TEST_RESULT:*)
            name="$(echo "$line" | cut -d: -f2)"
            result="$(echo "$line" | cut -d: -f3)"
            detail="$(echo "$line" | cut -d: -f4-)"
            if [ "$result" = "PASS" ]; then
                pass "$name — $detail"
            else
                fail "$name — $detail"
            fi
            ;;
        *) [ -n "$line" ] && echo "  $line" ;;
    esac
done <<< "$OUTPUT"

echo ""

# --- 2. Self-test: the checker must still detect the defect it guards --------

echo "fixture sweep — the checker's own verdicts on known-good/known-bad CSS:"
if ! run_checker "$FIXTURES/variants.css"; then
    echo "  FAIL: dark-mode-card-check.js failed on the fixture stylesheet"
    exit 1
fi

expect_verdict "dark-mode-host-cards-variants-discovered" PASS \
    "fixture variants are enumerated from the CSS"
expect_verdict "dark-mode-host-cards-fixture-good-card-text" PASS \
    "a dark wash over var(--card-bg) is readable"
expect_verdict "dark-mode-host-cards-fixture-good-muted-color" PASS \
    "muted labels are readable on the dark wash"
expect_verdict "dark-mode-host-cards-fixture-light-card-text" FAIL \
    "a light gradient with no dark override is the unfixed defect"
expect_verdict "dark-mode-host-cards-fixture-light-muted-color" FAIL \
    "muted labels are worse still on the light gradient"
expect_verdict "dark-mode-host-cards-fixture-tail-light-card-text" FAIL \
    "a gradient that starts dark and ends light is caught at its last stop"
expect_verdict "dark-mode-host-cards-fixture-alpha-wash-card-text" PASS \
    "a 4% white wash composites to a dark surface, it is not opaque white"
expect_verdict "dark-mode-host-cards-fixture-alpha-solid-card-text" FAIL \
    "a 98% white wash composites to a light surface"

# The pseudo-element rule in the fixture paints no card surface — enumerating it
# would measure a decoration rather than the card.
if printf '%s\n' "$OUTPUT" | grep -q "^TEST_RESULT:dark-mode-host-cards-fixture-good::before"; then
    fail "enumeration picked up a ::before decoration rule as a variant"
else
    pass "enumeration ignores ::before/::after decoration rules"
fi

echo ""

# --- 3. Guard-degradation: a broken enumeration must go red, not green ------

echo "guard-degradation — a stylesheet with no variants must not pass by vacuity:"
if ! run_checker "$FIXTURES/no-cards.css"; then
    echo "  FAIL: dark-mode-card-check.js failed on the empty fixture"
    exit 1
fi

expect_verdict "dark-mode-host-cards-variants-discovered" FAIL \
    "discovering zero .host-card variants is itself a failure"

echo ""
echo "==========================================="
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"

if [ "$PASS_COUNT" -eq 0 ]; then
    echo "TESTS FAILED - no results produced"
    exit 1
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "TESTS FAILED"
    exit 1
fi

echo "All tests passed!"
