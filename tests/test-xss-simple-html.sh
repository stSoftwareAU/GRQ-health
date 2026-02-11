#!/bin/bash
# Test for Issue #34: XSS prevention in simple.html
# Verifies that repo summary output escapes user-controlled data

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DENO="$HOME/.deno/bin/deno"
SIMPLE_HTML="$SCRIPT_DIR/../docs/simple.html"

echo "Testing Issue #34: XSS prevention in simple.html"
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

# Extract only the function definitions from simple.html (not auto-executing code)
# We extract all content between <script> and </script>, replacing auto-run calls with empty lines
extract_simple_functions() {
    sed -n '/<script>/,/<\/script>/p' "$SIMPLE_HTML" | \
        sed '1d;$d' | \
        sed 's/^[[:space:]]*checkHealth();//' | \
        sed 's/^[[:space:]]*setInterval(checkHealth, 30000);//'
}

OUTPUT=$(echo "
// Minimal DOM mock
const mockElements = {};
globalThis.document = {
    getElementById: function(id) {
        if (!mockElements[id]) {
            mockElements[id] = {
                innerHTML: '',
                textContent: '',
                className: '',
                style: { display: '' }
            };
        }
        return mockElements[id];
    }
};
globalThis.window = { location: { search: '' } };
globalThis.navigator = { onLine: true };

// Extract and run the simple.html functions
$(extract_simple_functions)

// Test 1: updateRepoSummary escapes repo names with XSS payload
{
    const repoStats = {
        total: 2,
        healthy: 1,
        warning: 0,
        error: 1,
        warningNames: [],
        errorNames: ['<script>alert(1)</script>'],
        errorMessages: ['<script>alert(1)</script>: <img src=x onerror=alert(2)>']
    };
    updateRepoSummary(repoStats, null);
    const html = mockElements['repoSummary']?.innerHTML || '';
    const hasRawScript = html.includes('<script>alert(1)</script>');
    const hasRawImg = html.includes('<img src=x onerror=alert(2)>');
    if (hasRawScript || hasRawImg) {
        console.log('TEST_RESULT:simple-repo-xss:FAIL:raw HTML found in repo summary: ' + (hasRawScript ? 'script ' : '') + (hasRawImg ? 'img' : ''));
    } else {
        console.log('TEST_RESULT:simple-repo-xss:PASS:repo names and error messages properly escaped');
    }
}

// Test 2: updateRepoSummary escapes warning names with XSS payload
{
    // Reset mock
    mockElements['repoSummary'] = { innerHTML: '', textContent: '', className: '', style: { display: '' } };
    const repoStats = {
        total: 1,
        healthy: 0,
        warning: 1,
        error: 0,
        warningNames: ['<b onmouseover=alert(1)>xss</b>'],
        errorNames: [],
        errorMessages: []
    };
    updateRepoSummary(repoStats, Math.floor(Date.now() / 1000));
    const html = mockElements['repoSummary']?.innerHTML || '';
    const hasRawHtml = html.includes('<b onmouseover=alert(1)>');
    if (hasRawHtml) {
        console.log('TEST_RESULT:simple-warning-xss:FAIL:raw HTML found in warning names');
    } else {
        console.log('TEST_RESULT:simple-warning-xss:PASS:warning names properly escaped');
    }
}
" | "$DENO" run - 2>&1)

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
