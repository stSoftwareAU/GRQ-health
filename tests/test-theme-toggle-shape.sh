#!/bin/bash
# Test for Issue #178: a grey square was painted behind the circular theme
# button in dark mode.
#
# Since Issue #163 the control is a single 38px circular button inside a plain
# container div. A leftover rule from the old multi-button pill control still
# painted a light scrim on that container, which has no border-radius, so the
# dark page showed a grey square around the moon icon.
#
# tests/theme-toggle-shape-check.js runs a small CSS cascade over
# docs/styles.css + docs/theme.css (in the order index.html loads them) against
# the element tree docs/theme.js actually builds, and asserts on the resulting
# appearance: the container must paint nothing perceptible behind the button
# unless it is rounded to the same circle, and the button must stay a visible
# circle in both themes. It also loads theme.js against a stub DOM to collect
# the classes the controller really applies, failing on any toggle rule keyed
# off a class that never appears.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCS_DIR="$ROOT_DIR/docs"
CHECKER="$SCRIPT_DIR/theme-toggle-shape-check.js"
DENO="$HOME/.deno/bin/deno"

echo "Testing Issue #178: no square behind the circular theme button"
echo "=============================================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

if [ ! -x "$DENO" ]; then
    echo "  FAIL: deno not found at $DENO — cannot verify theme control styling"
    exit 1
fi

# Fail loud if the checker itself blows up rather than reporting zero results.
if ! OUTPUT="$("$DENO" run --allow-read="$DOCS_DIR,$SCRIPT_DIR" "$CHECKER" "$DOCS_DIR" < /dev/null)"; then
    echo "  FAIL: theme-toggle-shape-check.js exited non-zero"
    echo "$OUTPUT"
    exit 1
fi

while IFS= read -r line; do
    case "$line" in
        TEST_RESULT:*)
            name="$(echo "$line" | cut -d: -f2)"
            result="$(echo "$line" | cut -d: -f3)"
            detail="$(echo "$line" | cut -d: -f4-)"
            if [ "$result" = "PASS" ]; then
                echo "  PASS: $name — $detail"
                PASS_COUNT=$((PASS_COUNT + 1))
            else
                echo "  FAIL: $name — $detail"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
            ;;
        *) [ -n "$line" ] && echo "  $line" ;;
    esac
done <<< "$OUTPUT"

if [ "$PASS_COUNT" -eq 0 ] && [ "$FAIL_COUNT" -eq 0 ]; then
    echo "  FAIL: checker reported no results"
    exit 1
fi

echo ""
echo "=============================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
