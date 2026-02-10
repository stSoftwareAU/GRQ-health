#!/bin/bash
# Test for Issue #34: XSS prevention via HTML escaping
# Verifies that escapeHtml() correctly escapes dangerous characters

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #34: HTML escaping for XSS prevention"
echo "===================================================="
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

OUTPUT=$(run_js_test '
// Test 1: escapeHtml escapes angle brackets
{
    const result = escapeHtml("<script>alert(1)</script>");
    const expected = "&lt;script&gt;alert(1)&lt;/script&gt;";
    if (result === expected) {
        console.log("TEST_RESULT:angle-brackets:PASS:angle brackets escaped correctly");
    } else {
        console.log("TEST_RESULT:angle-brackets:FAIL:expected " + expected + ", got " + result);
    }
}

// Test 2: escapeHtml escapes ampersands
{
    const result = escapeHtml("Tom & Jerry");
    const expected = "Tom &amp; Jerry";
    if (result === expected) {
        console.log("TEST_RESULT:ampersand:PASS:ampersand escaped correctly");
    } else {
        console.log("TEST_RESULT:ampersand:FAIL:expected " + expected + ", got " + result);
    }
}

// Test 3: escapeHtml escapes double quotes
{
    const result = escapeHtml("say \"hello\"");
    const expected = "say &quot;hello&quot;";
    if (result === expected) {
        console.log("TEST_RESULT:double-quotes:PASS:double quotes escaped correctly");
    } else {
        console.log("TEST_RESULT:double-quotes:FAIL:expected " + expected + ", got " + result);
    }
}

// Test 4: escapeHtml escapes single quotes
{
    const result = escapeHtml("it'\''s fine");
    const expected = "it&#039;s fine";
    if (result === expected) {
        console.log("TEST_RESULT:single-quotes:PASS:single quotes escaped correctly");
    } else {
        console.log("TEST_RESULT:single-quotes:FAIL:expected " + expected + ", got " + result);
    }
}

// Test 5: escapeHtml handles null/undefined/empty
{
    const r1 = escapeHtml(null);
    const r2 = escapeHtml(undefined);
    const r3 = escapeHtml("");
    if (r1 === "" && r2 === "" && r3 === "") {
        console.log("TEST_RESULT:falsy-values:PASS:null/undefined/empty return empty string");
    } else {
        console.log("TEST_RESULT:falsy-values:FAIL:expected empty strings, got [" + r1 + "], [" + r2 + "], [" + r3 + "]");
    }
}

// Test 6: escapeHtml handles numbers
{
    const result = escapeHtml(42);
    if (result === "42") {
        console.log("TEST_RESULT:number-input:PASS:numbers converted to string");
    } else {
        console.log("TEST_RESULT:number-input:FAIL:expected 42, got " + result);
    }
}

// Test 7: escapeHtml handles combined XSS payload
{
    const payload = "<img src=x onerror=\"alert(&'\''XSS'\'')\"/>";
    const result = escapeHtml(payload);
    // Should not contain any unescaped < > " characters
    const hasRawAngle = result.includes("<") || result.includes(">");
    const hasRawQuote = result.includes("\"");
    if (!hasRawAngle && !hasRawQuote) {
        console.log("TEST_RESULT:xss-payload:PASS:XSS payload fully escaped");
    } else {
        console.log("TEST_RESULT:xss-payload:FAIL:XSS payload not fully escaped: " + result);
    }
}

// Test 8: escapeHtml preserves safe text unchanged
{
    const safe = "Hello World 123";
    const result = escapeHtml(safe);
    if (result === safe) {
        console.log("TEST_RESULT:safe-text:PASS:safe text unchanged");
    } else {
        console.log("TEST_RESULT:safe-text:FAIL:expected " + safe + ", got " + result);
    }
}
')

while IFS= read -r line; do
    case "$line" in
        TEST_RESULT:*)
            local_name="$(echo "$line" | cut -d: -f2)"
            local_result="$(echo "$line" | cut -d: -f3)"
            local_detail="$(echo "$line" | cut -d: -f4-)"
            if [ "$local_result" = "PASS" ]; then
                pass_test "$local_name — $local_detail"
            else
                fail_test "$local_name — $local_detail"
            fi
            ;;
    esac
done <<< "$OUTPUT"

echo ""
echo "===================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
