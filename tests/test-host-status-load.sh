#!/bin/bash
# Test for Issue #213: the dashboard loads per-host status documents through a
# manifest and merges the legacy fleet-wide index.json underneath them.
#
# tests/host-status-load-check.js executes the real docs/host-status.js against
# a stub fetch and asserts on the data it returns: per-host documents win over
# the legacy entry, hosts that have not migrated still show, a missing document
# is surfaced rather than swallowed, and a hostile manifest entry is never
# fetched.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCS_DIR="$ROOT_DIR/docs"
CHECKER="$SCRIPT_DIR/host-status-load-check.js"
# shellcheck source=tests/find-deno.sh
source "$SCRIPT_DIR/find-deno.sh"

echo "Testing Issue #213: per-host dashboard data loading"
echo "==================================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

if [ ! -x "$DENO" ]; then
    echo "  FAIL: deno not found at $DENO — cannot verify the data loader"
    exit 1
fi

# Fail loud if the checker itself blows up rather than reporting zero results.
if ! OUTPUT="$("$DENO" run --allow-read="$DOCS_DIR,$SCRIPT_DIR" "$CHECKER" "$DOCS_DIR" < /dev/null)"; then
    echo "  FAIL: host-status-load-check.js exited non-zero"
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
echo "==================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
