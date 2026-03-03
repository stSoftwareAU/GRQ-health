#!/bin/bash
# Test for Issue #34: XSS prevention in dashboard HTML generation
# Verifies that createHostCard and other HTML-generating functions
# properly escape user-controlled data from JSON

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #34: XSS prevention in HTML generation"
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

# createHostCard (lines 702-984) is outside the default pure-function range
# but it only generates HTML strings — no real DOM access needed.
# Extract it separately and provide a minimal DOM mock.
extract_card_function() {
    sed -n '725,1031p' "$SCRIPT_DIR/../docs/dashboard.js"
}

# renderRepoHealth (lines 347-420) uses document.getElementById
# but we mock it. It's already within the pure range.

run_js_test_with_card() {
    local test_code="$1"
    local functions
    functions="$(extract_pure_functions)"
    local card_fn
    card_fn="$(extract_card_function)"

    # Provide globals that are declared outside the pure-function range
    local globals="let repoHealthData = { repos: [] }; const diskWarningState = {};"

    echo "${globals}
${functions}
${card_fn}
${test_code}" | "$DENO" run -
}

OUTPUT=$(run_js_test_with_card '
// Mock allHosts for createHostCard
var allHosts = [];

// Test 1: createHostCard escapes hostname with XSS payload
{
    const xssHostname = "<script>alert(1)</script>";
    const data = {
        heart_beat_ts: Math.floor(Date.now() / 1000),
        os_info: "macOS",
        os_version: "15.5",
        uptime: 86400,
        used_disk_percent: "30",
        mem_usage_percent: "50",
        cpu_load: "10%",
        network_status: "connected",
        timezone: "AEST"
    };
    const html = createHostCard(xssHostname, data);
    // The raw <script> tag should NOT appear — it should be escaped
    if (html.includes("<script>alert(1)</script>")) {
        console.log("TEST_RESULT:hostname-xss:FAIL:raw script tag found in hostname");
    } else if (html.includes("&lt;script&gt;")) {
        console.log("TEST_RESULT:hostname-xss:PASS:hostname XSS payload properly escaped");
    } else {
        console.log("TEST_RESULT:hostname-xss:FAIL:hostname not found at all in output");
    }
}

// Test 2: createHostCard escapes os_info with XSS payload
{
    const hostname = "safe-host";
    const data = {
        heart_beat_ts: Math.floor(Date.now() / 1000),
        os_info: "<img src=x onerror=alert(1)>",
        os_version: "15.5",
        uptime: 86400,
        used_disk_percent: "30",
        mem_usage_percent: "50",
        cpu_load: "10%",
        network_status: "connected",
        timezone: "AEST"
    };
    const html = createHostCard(hostname, data);
    if (html.includes("<img src=x onerror=alert(1)>")) {
        console.log("TEST_RESULT:osinfo-xss:FAIL:raw img tag found in os_info");
    } else if (html.includes("&lt;img")) {
        console.log("TEST_RESULT:osinfo-xss:PASS:os_info XSS payload properly escaped");
    } else {
        console.log("TEST_RESULT:osinfo-xss:FAIL:os_info not found at all in output");
    }
}

// Test 3: createHostCard escapes info field with XSS payload
{
    const hostname = "safe-host";
    const data = {
        heart_beat_ts: Math.floor(Date.now() / 1000),
        os_info: "macOS",
        os_version: "15.5",
        uptime: 86400,
        used_disk_percent: "30",
        mem_usage_percent: "50",
        cpu_load: "10%",
        network_status: "connected",
        timezone: "AEST",
        info: "<script>steal(cookies)</script>"
    };
    const html = createHostCard(hostname, data);
    if (html.includes("<script>steal(cookies)</script>")) {
        console.log("TEST_RESULT:info-xss:FAIL:raw script tag found in info field");
    } else if (html.includes("&lt;script&gt;steal(cookies)&lt;/script&gt;")) {
        console.log("TEST_RESULT:info-xss:PASS:info field XSS payload properly escaped");
    } else {
        console.log("TEST_RESULT:info-xss:FAIL:info field not found at all in output");
    }
}

// Test 4: createHostCard escapes location with XSS payload
{
    const hostname = "safe-host";
    const data = {
        heart_beat_ts: Math.floor(Date.now() / 1000),
        os_info: "macOS",
        os_version: "15.5",
        uptime: 86400,
        used_disk_percent: "30",
        mem_usage_percent: "50",
        cpu_load: "10%",
        network_status: "connected",
        timezone: "AEST",
        location: "\"onmouseover=\"alert(1)\""
    };
    const html = createHostCard(hostname, data);
    if (html.includes("\"onmouseover=\"alert(1)\"")) {
        console.log("TEST_RESULT:location-xss:FAIL:raw event handler found in location");
    } else if (html.includes("&quot;onmouseover=&quot;alert(1)&quot;")) {
        console.log("TEST_RESULT:location-xss:PASS:location XSS payload properly escaped");
    } else {
        console.log("TEST_RESULT:location-xss:FAIL:unexpected escaping: check location handling");
    }
}

// Test 5: createHostCard escapes config_warning with XSS payload
{
    const hostname = "safe-host";
    const data = {
        heart_beat_ts: Math.floor(Date.now() / 1000),
        os_info: "macOS",
        os_version: "15.5",
        uptime: 86400,
        used_disk_percent: "30",
        mem_usage_percent: "50",
        cpu_load: "10%",
        network_status: "connected",
        timezone: "AEST",
        config_warning: "<b onmouseover=alert(1)>hover me</b>"
    };
    const html = createHostCard(hostname, data);
    if (html.includes("<b onmouseover=alert(1)>")) {
        console.log("TEST_RESULT:config-warning-xss:FAIL:raw HTML found in config_warning");
    } else if (html.includes("&lt;b onmouseover=alert(1)&gt;")) {
        console.log("TEST_RESULT:config-warning-xss:PASS:config_warning XSS payload escaped");
    } else {
        console.log("TEST_RESULT:config-warning-xss:FAIL:config_warning content not found");
    }
}

// Test 6: createHostCard escapes dead host fields
{
    const hostname = "<img src=x onerror=alert(1)>";
    const data = {
        death_date: "<script>alert(2)</script>",
        location: "<b>xss</b>",
        emoji: "💀",
        os_info: "<iframe>",
        info: "<script>alert(3)</script>"
    };
    const html = createHostCard(hostname, data);
    const hasRawScript = html.includes("<script>alert");
    const hasRawImg = html.includes("<img src=x onerror");
    const hasRawIframe = html.includes("<iframe>");
    if (hasRawScript || hasRawImg || hasRawIframe) {
        console.log("TEST_RESULT:dead-host-xss:FAIL:raw HTML tags found in dead host card");
    } else {
        console.log("TEST_RESULT:dead-host-xss:PASS:dead host card fields properly escaped");
    }
}

// Test 7: escapeHtml handles zero correctly (not treated as falsy)
{
    const result = escapeHtml(0);
    if (result === "0") {
        console.log("TEST_RESULT:zero-handling:PASS:zero is preserved, not treated as falsy");
    } else {
        console.log("TEST_RESULT:zero-handling:FAIL:expected 0, got " + result);
    }
}

// Test 8: renderRepoHealth escapes repo name with XSS payload
{
    // Mock DOM elements needed by renderRepoHealth
    const mockElements = {};
    const origGetById = globalThis.document?.getElementById;
    globalThis.document = {
        getElementById: function(id) {
            if (!mockElements[id]) {
                mockElements[id] = {
                    innerHTML: "",
                    textContent: "",
                    style: { display: "" }
                };
            }
            return mockElements[id];
        }
    };

    // Set up repoHealthData with XSS payload
    repoHealthData = {
        repos: [{
            name: "<script>alert(1)</script>",
            last_commit_ts: Math.floor(Date.now() / 1000) - 3600,
            error_message: "<img src=x onerror=alert(2)>"
        }]
    };

    renderRepoHealth();

    const listHtml = mockElements["repoHealthList"]?.innerHTML || "";
    const hasRawScript = listHtml.includes("<script>alert(1)</script>");
    const hasRawImg = listHtml.includes("<img src=x onerror=alert(2)>");
    if (hasRawScript || hasRawImg) {
        console.log("TEST_RESULT:repo-name-xss:FAIL:raw HTML in repo health output");
    } else if (listHtml.includes("&lt;script&gt;") && listHtml.includes("&lt;img")) {
        console.log("TEST_RESULT:repo-name-xss:PASS:repo name and error_message escaped");
    } else {
        console.log("TEST_RESULT:repo-name-xss:FAIL:escaped content not found in output");
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
