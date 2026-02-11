#!/bin/bash
# Test for Issue #34: XSS prevention in log-viewer.html
# Verifies that hostname and filePath are escaped in innerHTML

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DENO="$HOME/.deno/bin/deno"
LOG_VIEWER="$SCRIPT_DIR/../docs/log-viewer.html"

echo "Testing Issue #34: XSS prevention in log-viewer.html"
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

# Extract the script block from log-viewer.html, stripping the tags
extract_log_viewer_script() {
    sed -n '/<script>/,/<\/script>/p' "$LOG_VIEWER" | sed '1d;$d'
}

# Test 1: Error path — hostname and error.message are escaped
OUTPUT_ERROR=$(echo '
const mockElements = {};
globalThis.document = {
    getElementById: function(id) {
        if (!mockElements[id]) {
            mockElements[id] = { innerHTML: "", textContent: "", className: "", style: { display: "" } };
        }
        return mockElements[id];
    },
    querySelector: function() { return null; },
    title: ""
};
globalThis.window = { location: { search: "?file=./<script>alert(1)</script>/node.log" } };
globalThis.navigator = { onLine: true };
globalThis.setTimeout = function(fn) { fn(); };
globalThis.fetch = function() {
    return Promise.reject(new Error("<img src=x onerror=alert(2)>"));
};
' "$(extract_log_viewer_script)" '
await new Promise(r => setTimeout(r, 100));
const html = mockElements["logContainer"]?.innerHTML || "";
const hasRawScript = html.includes("<script>alert(1)</script>");
const hasRawImg = html.includes("<img src=x onerror=alert(2)>");
if (hasRawScript || hasRawImg) {
    console.log("TEST_RESULT:error-path-xss:FAIL:raw HTML in error output: " + (hasRawScript ? "script " : "") + (hasRawImg ? "img" : ""));
} else {
    console.log("TEST_RESULT:error-path-xss:PASS:error path output properly escaped");
}
' | "$DENO" run - 2>&1)

# Test 2: Success path — hostname is escaped in log header
OUTPUT_SUCCESS=$(echo '
const mockElements = {};
globalThis.document = {
    getElementById: function(id) {
        if (!mockElements[id]) {
            mockElements[id] = { innerHTML: "", textContent: "", className: "", style: { display: "" } };
        }
        return mockElements[id];
    },
    querySelector: function() { return null; },
    title: ""
};
globalThis.window = { location: { search: "?file=./<img>xss/node.log" } };
globalThis.navigator = { onLine: true };
const origSetTimeout = globalThis.setTimeout;
globalThis.setTimeout = function(fn, ms) { origSetTimeout(fn, Math.min(ms || 0, 50)); };
globalThis.fetch = function() {
    return Promise.resolve({
        ok: true,
        text: function() { return Promise.resolve("Normal log line\nAnother line\n"); }
    });
};
' "$(extract_log_viewer_script)" '
await new Promise(r => origSetTimeout(r, 500));
const html = mockElements["logContainer"]?.innerHTML || "";
// hostname extracted from filePath is "<img>xss"
const hasRawImg = html.includes("<img>xss");
if (hasRawImg) {
    console.log("TEST_RESULT:success-path-xss:FAIL:raw HTML tag in log header hostname");
} else if (html.includes("&lt;img&gt;xss")) {
    console.log("TEST_RESULT:success-path-xss:PASS:hostname escaped in log header");
} else {
    console.log("TEST_RESULT:success-path-xss:FAIL:escaped hostname not found in output");
}
' | "$DENO" run - 2>&1)

# Parse results from both tests
for OUTPUT in "$OUTPUT_ERROR" "$OUTPUT_SUCCESS"; do
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
done

echo ""
echo "===================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
