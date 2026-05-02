#!/bin/bash
# Test for Issue #29: Normal operational messages should not be flagged as errors
# Extracts processLogContent from log-viewer.html and tests classification
# of various log lines to ensure correct error/warning detection.

set -e

DENO="$HOME/.deno/bin/deno"

echo "Testing Issue #29: Log line classification"
echo "============================================="
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

# Extract the processLogContent function from log-viewer.html
# We extract just the classification logic and adapt it for testing
# by creating a classifyLine function that returns the CSS class.
OUTPUT=$("$DENO" run - <<'DENO_SCRIPT'
// Extract classification logic matching log-viewer.html processLogContent
// This must mirror the actual function to test real behaviour
function classifyLine(line) {
    const isStackTraceLine = /^\s+at /.test(line);
    const isCStackTraceLine = /^\s+\d+\s+[^\s]+\s+0x[0-9a-fA-F]+/.test(line);

    // Issue #73: Skip directory listing lines (ls -la output) — filenames
    // may contain keywords like ERROR or Exception that are not real errors
    const isDirListingLine = /^[dlcbps-][rwxsStT-]{9}/.test(line);
    if (isDirListingLine) {
        return 'normal';
    }

    if (line.includes('ERROR') ||
        line.includes('Exception') ||
        line.startsWith('Error:') ||
        /Discovery failed for .+ after .+: Error:/.test(line) ||
        /\bfailed\b.*Error:/.test(line) ||
        /Fatal JavaScript out of memory/.test(line) ||
        /==== C stack trace/.test(line) ||
        /Fatal error/.test(line)) {
        return 'error-line';
    } else if (line.includes('\u274C')) {  // ❌
        return 'error-line';
    } else if (isStackTraceLine || isCStackTraceLine) {
        return 'stack-trace-line';
    } else if (line.includes('WARNING') || line.includes('Warning:') || line.includes('\u26A0\uFE0F')) {  // ⚠️
        return 'warning-line';
    } else if (line.includes('DEBUG:')) {
        return 'debug-line';
    } else {
        return 'normal';
    }
}

// Test 1: Normal "Discovery failed to find improvements" should NOT be an error
{
    const line = "🛍️ Discovery failed to find any improvements, storing failure cache.";
    const cls = classifyLine(line);
    if (cls === "normal") {
        console.log("TEST_RESULT:discovery-no-improvements:PASS:normal operational message not flagged");
    } else {
        console.log("TEST_RESULT:discovery-no-improvements:FAIL:expected normal, got " + cls);
    }
}

// Test 2: Actual discovery timeout error SHOULD be an error
{
    const line = "Discovery failed for creature fa999cac after 240.0s: Error: Discovery timeout";
    const cls = classifyLine(line);
    if (cls === "error-line") {
        console.log("TEST_RESULT:discovery-timeout-error:PASS:real discovery error flagged correctly");
    } else {
        console.log("TEST_RESULT:discovery-timeout-error:FAIL:expected error-line, got " + cls);
    }
}

// Test 3: Git sync output should NOT be flagged
{
    const line = "GRQ-cluster synced with remote (validation skipped)";
    const cls = classifyLine(line);
    if (cls === "normal") {
        console.log("TEST_RESULT:git-sync-normal:PASS:git sync message not flagged");
    } else {
        console.log("TEST_RESULT:git-sync-normal:FAIL:expected normal, got " + cls);
    }
}

// Test 4: Git branch output should NOT be flagged
{
    const line = "branch 'main' set up to track 'origin/main'.";
    const cls = classifyLine(line);
    if (cls === "normal") {
        console.log("TEST_RESULT:git-branch-normal:PASS:git branch message not flagged");
    } else {
        console.log("TEST_RESULT:git-branch-normal:FAIL:expected normal, got " + cls);
    }
}

// Test 5: Real ERROR line should be flagged
{
    const line = "ERROR: Something went wrong";
    const cls = classifyLine(line);
    if (cls === "error-line") {
        console.log("TEST_RESULT:real-error:PASS:ERROR line flagged correctly");
    } else {
        console.log("TEST_RESULT:real-error:FAIL:expected error-line, got " + cls);
    }
}

// Test 6: Exception line should be flagged
{
    const line = "NullPointerException at line 42";
    const cls = classifyLine(line);
    if (cls === "error-line") {
        console.log("TEST_RESULT:exception-line:PASS:Exception line flagged correctly");
    } else {
        console.log("TEST_RESULT:exception-line:FAIL:expected error-line, got " + cls);
    }
}

// Test 7: Warning line should be classified as warning
{
    const line = "⚠️ Something needs attention";
    const cls = classifyLine(line);
    if (cls === "warning-line") {
        console.log("TEST_RESULT:warning-emoji:PASS:warning emoji flagged correctly");
    } else {
        console.log("TEST_RESULT:warning-emoji:FAIL:expected warning-line, got " + cls);
    }
}

// Test 8: Stack trace line should be classified as stack trace
{
    const line = "    at Object.main (file.js:10:5)";
    const cls = classifyLine(line);
    if (cls === "stack-trace-line") {
        console.log("TEST_RESULT:stack-trace:PASS:stack trace line flagged correctly");
    } else {
        console.log("TEST_RESULT:stack-trace:FAIL:expected stack-trace-line, got " + cls);
    }
}

// Test 9: Failed with Error should still be caught
{
    const line = "Task failed with Error: timeout reached";
    const cls = classifyLine(line);
    if (cls === "error-line") {
        console.log("TEST_RESULT:failed-with-error:PASS:failed+Error caught correctly");
    } else {
        console.log("TEST_RESULT:failed-with-error:FAIL:expected error-line, got " + cls);
    }
}

// Test 10: Fatal error should be caught
{
    const line = "Fatal error in something";
    const cls = classifyLine(line);
    if (cls === "error-line") {
        console.log("TEST_RESULT:fatal-error:PASS:Fatal error caught correctly");
    } else {
        console.log("TEST_RESULT:fatal-error:FAIL:expected error-line, got " + cls);
    }
}

// Test 11: Failure emoji should be caught
{
    const line = "❌ Build failed";
    const cls = classifyLine(line);
    if (cls === "error-line") {
        console.log("TEST_RESULT:failure-emoji:PASS:failure emoji flagged correctly");
    } else {
        console.log("TEST_RESULT:failure-emoji:FAIL:expected error-line, got " + cls);
    }
}

// Test 12: C stack trace line should be caught
{
    const line = "    1 node             0x0000000104d3b2c4 some_func";
    const cls = classifyLine(line);
    if (cls === "stack-trace-line") {
        console.log("TEST_RESULT:c-stack-trace:PASS:C stack trace flagged correctly");
    } else {
        console.log("TEST_RESULT:c-stack-trace:FAIL:expected stack-trace-line, got " + cls);
    }
}

// Issue #73: Directory listing lines with ERROR in filenames should NOT be flagged
// Test 13: ls -la output with CRISPR-ERROR filename should be normal
{
    const line = "-rw-r--r--  1 rocket staff  2003073 Oct 17 05:22 .CRISPR-ERROR-Industry 5th percentile.json";
    const cls = classifyLine(line);
    if (cls === "normal") {
        console.log("TEST_RESULT:dir-listing-error-filename:PASS:directory listing with ERROR filename not flagged");
    } else {
        console.log("TEST_RESULT:dir-listing-error-filename:FAIL:expected normal, got " + cls);
    }
}

// Test 14: ls -la output with another CRISPR-ERROR filename
{
    const line = "-rw-r--r--  1 rocket staff  2003134 Oct 17 05:22 .CRISPR-ERROR-Industry 95th percentile V2.json";
    const cls = classifyLine(line);
    if (cls === "normal") {
        console.log("TEST_RESULT:dir-listing-error-filename-2:PASS:directory listing with ERROR filename not flagged");
    } else {
        console.log("TEST_RESULT:dir-listing-error-filename-2:FAIL:expected normal, got " + cls);
    }
}

// Test 15: ls -la directory line with ERROR in name should be normal
{
    const line = "drwxr-xr-x  46 rocket staff  1472 Apr 16 05:29 .CRISPR-ERROR-Insider-Bullish-7-v1.json";
    const cls = classifyLine(line);
    if (cls === "normal") {
        console.log("TEST_RESULT:dir-listing-error-dirname:PASS:directory listing with ERROR dirname not flagged");
    } else {
        console.log("TEST_RESULT:dir-listing-error-dirname:FAIL:expected normal, got " + cls);
    }
}

// Test 16: ls -la output with Exception in filename should be normal
{
    const line = "-rw-r--r--  1 user staff  1024 Jan 10 12:00 ExceptionReport-2026.txt";
    const cls = classifyLine(line);
    if (cls === "normal") {
        console.log("TEST_RESULT:dir-listing-exception-filename:PASS:directory listing with Exception filename not flagged");
    } else {
        console.log("TEST_RESULT:dir-listing-exception-filename:FAIL:expected normal, got " + cls);
    }
}

// Test 17: ls -la output with WARNING in filename should be normal
{
    const line = "-rw-r--r--  1 user staff  512 Mar 05 09:30 WARNING-old-report.csv";
    const cls = classifyLine(line);
    if (cls === "normal") {
        console.log("TEST_RESULT:dir-listing-warning-filename:PASS:directory listing with WARNING filename not flagged");
    } else {
        console.log("TEST_RESULT:dir-listing-warning-filename:FAIL:expected normal, got " + cls);
    }
}

// Test 18: Real ERROR line should still be flagged (not a directory listing)
{
    const line = "ERROR: Disk space critically low";
    const cls = classifyLine(line);
    if (cls === "error-line") {
        console.log("TEST_RESULT:real-error-still-flagged:PASS:real ERROR still flagged after dir listing fix");
    } else {
        console.log("TEST_RESULT:real-error-still-flagged:FAIL:expected error-line, got " + cls);
    }
}

// Test 19: ls total line should be normal (not a directory listing but also not an error)
{
    const line = "total 47056";
    const cls = classifyLine(line);
    if (cls === "normal") {
        console.log("TEST_RESULT:ls-total-line:PASS:ls total line is normal");
    } else {
        console.log("TEST_RESULT:ls-total-line:FAIL:expected normal, got " + cls);
    }
}
DENO_SCRIPT
)

while IFS= read -r line; do
    case "$line" in
        TEST_RESULT:*) check_result "$line" ;;
    esac
done <<< "$OUTPUT"

echo ""
echo "============================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
