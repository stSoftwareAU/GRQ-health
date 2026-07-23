#!/bin/bash
# Test for Issue #161: light/dark/auto theme toggle with remembered choice.
# Verifies the pure theme helpers in docs/theme.js resolve modes correctly and
# that each dashboard page wires up the shared controller.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
THEME_JS="$ROOT_DIR/docs/theme.js"
DENO="$HOME/.deno/bin/deno"

echo "Testing Issue #161: light/dark/auto theme toggle"
echo "================================================"
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() {
    echo "  PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail_test() {
    echo "  FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# --- Pure function behaviour via Deno -------------------------------------
# theme.js guards its DOM code behind `typeof document === 'undefined'`, so it
# loads cleanly under Deno and exposes the pure helpers on globalThis.GRQTheme.
OUTPUT=$(printf '%s\n%s\n' "$(cat "$THEME_JS")" '
const { sanitiseThemeMode, resolveTheme } = globalThis.GRQTheme;

// sanitiseThemeMode: valid modes pass through unchanged.
{
    const ok = ["light", "dark", "auto"].every((m) => sanitiseThemeMode(m) === m);
    console.log("TEST_RESULT:sanitise-valid:" + (ok ? "PASS" : "FAIL") + ":valid modes preserved");
}

// sanitiseThemeMode: unknown / null / empty fall back to auto.
{
    const ok = sanitiseThemeMode("purple") === "auto" &&
               sanitiseThemeMode(null) === "auto" &&
               sanitiseThemeMode(undefined) === "auto" &&
               sanitiseThemeMode("") === "auto";
    console.log("TEST_RESULT:sanitise-default:" + (ok ? "PASS" : "FAIL") + ":invalid modes default to auto");
}

// resolveTheme: explicit modes ignore the OS preference.
{
    const ok = resolveTheme("light", true) === "light" &&
               resolveTheme("light", false) === "light" &&
               resolveTheme("dark", false) === "dark" &&
               resolveTheme("dark", true) === "dark";
    console.log("TEST_RESULT:resolve-explicit:" + (ok ? "PASS" : "FAIL") + ":explicit modes ignore OS");
}

// resolveTheme: auto follows the OS preference.
{
    const ok = resolveTheme("auto", true) === "dark" &&
               resolveTheme("auto", false) === "light";
    console.log("TEST_RESULT:resolve-auto:" + (ok ? "PASS" : "FAIL") + ":auto follows OS preference");
}

// resolveTheme: invalid mode behaves like auto.
{
    const ok = resolveTheme("nope", true) === "dark" &&
               resolveTheme("nope", false) === "light";
    console.log("TEST_RESULT:resolve-invalid:" + (ok ? "PASS" : "FAIL") + ":invalid mode treated as auto");
}
' | "$DENO" run -)

while IFS= read -r line; do
    case "$line" in
        TEST_RESULT:*)
            name="$(echo "$line" | cut -d: -f2)"
            result="$(echo "$line" | cut -d: -f3)"
            detail="$(echo "$line" | cut -d: -f4-)"
            if [ "$result" = "PASS" ]; then
                pass_test "$name — $detail"
            else
                fail_test "$name — $detail"
            fi
            ;;
    esac
done <<< "$OUTPUT"

# --- Wiring checks: every page loads the controller -----------------------
for page in index.html simple.html log-viewer.html; do
    if grep -q 'theme.js' "$ROOT_DIR/docs/$page"; then
        pass_test "$page loads theme.js"
    else
        fail_test "$page does not load theme.js"
    fi
    if grep -q 'id="theme-toggle"' "$ROOT_DIR/docs/$page"; then
        pass_test "$page has a theme-toggle placeholder"
    else
        fail_test "$page is missing the theme-toggle placeholder"
    fi
done

echo ""
echo "================================================"
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
