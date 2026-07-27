#!/bin/bash
# Test for Issue #173: the decorative host-card emoji pseudo-elements must not
# paint over the status badge.
#
# `.host-card.mia::before` (🌐) was absolutely positioned at `z-index: 1` in the
# same top-right corner the `.health-status` badge occupies, so it painted over
# "OFF THE GRID" and clipped the final characters. `.mobile` and
# `.outdated-macos` carried the identical pattern.
#
# tests/decoration-stacking-check.js closes the gap by *enumerating* the
# `.host-card.<variant>::before/::after` rules in docs/styles.css and resolving
# the CSS painting order (CSS 2.1 Appendix E) of each decoration against the
# badge, instead of asserting any particular declaration. A newly decorated
# variant is covered without editing this test, and a fix that merely nudges the
# emoji's `right` offset — which would re-collide on a different status string —
# does not satisfy it.
#
# Two self-tests keep the guard honest:
#   * tests/fixtures/decoration-stacking/variants.css carries known-good and
#     known-bad decorations, so a checker that stopped modelling painting order,
#     pointer-events or stacking-context escape fails.
#   * tests/fixtures/decoration-stacking/no-decorations.css has no decorations
#     at all, so a broken enumeration goes red instead of green-by-vacuity.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STYLES_CSS="$ROOT_DIR/docs/styles.css"
FIXTURES="$SCRIPT_DIR/fixtures/decoration-stacking"
CHECKER="$SCRIPT_DIR/decoration-stacking-check.js"
DENO="$HOME/.deno/bin/deno"

echo "Testing Issue #173: host-card decoration stacking order"
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
    echo "  FAIL: deno not found at $DENO — cannot verify decoration stacking"
    exit 1
fi

# --- 1. The real stylesheet: every decoration must paint behind the badge ----

echo "docs/styles.css — every .host-card decoration:"
if ! run_checker "$STYLES_CSS"; then
    echo "  FAIL: decoration-stacking-check.js failed on docs/styles.css"
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

# The three decorated variants named in the issue must actually be among them,
# so a regression that deletes a rule cannot quietly shrink the sweep.
for variant in mia mobile outdated-macos; do
    for pseudo in before after; do
        if printf '%s\n' "$OUTPUT" |
            grep -q "^TEST_RESULT:decoration-stacking-${variant}-${pseudo}-behind-badge:"; then
            pass "decoration .host-card.${variant}::${pseudo} is covered by the sweep"
        else
            fail "decoration .host-card.${variant}::${pseudo} was not swept"
        fi
    done
done

echo ""

# --- 2. Self-test: the checker must still detect the defect it guards --------

echo "fixture sweep — the checker's own verdicts on known-good/known-bad CSS:"
if ! run_checker "$FIXTURES/variants.css"; then
    echo "  FAIL: decoration-stacking-check.js failed on the fixture stylesheet"
    exit 1
fi

expect_verdict "decoration-stacking-decorations-discovered" PASS \
    "fixture decorations are enumerated from the CSS"
expect_verdict "decoration-stacking-good-before-behind-badge" PASS \
    "a negative z-index inside an isolated card paints below the badge"
expect_verdict "decoration-stacking-good-before-stays-in-card" PASS \
    "an isolated card keeps its negative-z decoration visible"
expect_verdict "decoration-stacking-good-before-pointer-events" PASS \
    "pointer-events: none keeps the decoration inert"
expect_verdict "decoration-stacking-good-before-animation" PASS \
    "the float animation survives the fix"
expect_verdict "decoration-stacking-overlay-before-behind-badge" FAIL \
    "z-index: 1 over an in-flow badge is the unfixed defect"
expect_verdict "decoration-stacking-flat-before-behind-badge" FAIL \
    "z-index: 0 still paints a positioned box above in-flow content"
expect_verdict "decoration-stacking-escapes-before-stays-in-card" FAIL \
    "a negative z-index escapes a card that is not a stacking context"
expect_verdict "decoration-stacking-taps-before-pointer-events" FAIL \
    "a decoration without pointer-events: none swallows taps"
expect_verdict "decoration-stacking-frozen-before-animation" FAIL \
    "a decoration that lost its animation is caught"

echo ""

# --- 3. Guard-degradation: no decorations must go red, not green ------------

echo "guard-degradation — a stylesheet with no decorations must not pass by vacuity:"
if ! run_checker "$FIXTURES/no-decorations.css"; then
    echo "  FAIL: decoration-stacking-check.js failed on the empty fixture"
    exit 1
fi

expect_verdict "decoration-stacking-decorations-discovered" FAIL \
    "discovering zero decorations is itself a failure"

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
