#!/bin/bash
# Test for Issue #165: dark mode showed a white Users table.
#
# Bootstrap 5.3 gives `.table` a light `--bs-table-bg` (it defaults to
# `--bs-body-bg`, i.e. white) and a near-black `--bs-table-color`. The dashboard
# switches themes with its own `[data-theme="dark"]` attribute, so those
# Bootstrap defaults survived and the per-host Users table rendered as a white
# block on the dark page.
#
# tests/dark-mode-table-check.js resolves the colours the dark theme actually
# applies to the table — following `var(--x)` references into the dark palette —
# and asserts on their *behaviour*: measured relative luminance and WCAG 2.1
# contrast ratios, not any particular colour literal. Retuning the palette keeps
# these tests passing; regressing to a light table does not.
#
# Issue #170 extends the same harness to the "Off the Grid" (MIA) host card,
# whose base rule hardcodes a near-white mint gradient. Without a dark surface
# of its own it renders the dark palette's light text on a light background.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STYLES_CSS="$ROOT_DIR/docs/styles.css"
CHECKER="$SCRIPT_DIR/dark-mode-table-check.js"
DENO="$HOME/.deno/bin/deno"

echo "Testing Issues #165/#170: dark mode surface colours"
echo "==========================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

check_result() {
    local line="$1"
    local name result detail
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
}

if [ ! -x "$DENO" ]; then
    echo "  FAIL: deno not found at $DENO — cannot verify dark mode colours"
    exit 1
fi

# Fail loud if the checker itself blows up rather than reporting zero results.
if ! OUTPUT="$("$DENO" run --allow-read="$STYLES_CSS" "$CHECKER" "$STYLES_CSS" < /dev/null)"; then
    echo "  FAIL: dark-mode-table-check.js exited non-zero"
    echo "$OUTPUT"
    exit 1
fi

while IFS= read -r line; do
    case "$line" in
        TEST_RESULT:*) check_result "$line" ;;
        *) [ -n "$line" ] && echo "  $line" ;;
    esac
done <<< "$OUTPUT"

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
