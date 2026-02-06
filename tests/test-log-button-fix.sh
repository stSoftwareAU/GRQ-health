#!/bin/bash
# Test script for Issue #13: Per-user log button behaviour
#
# These are functional "what" tests that call the dashboard functions with real
# test data and verify the results. They do NOT grep source code.
#
# Key behaviour under test:
# - Single-user hosts should show the main "View Log" button (showUserTable = false)
# - Multi-user hosts (2+) should hide the main button and show per-user log buttons
# - Per-user log URLs are correctly generated using sanitizeUserSlug

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #13: Per-user log button behaviour"
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

TEST_OUTPUT=$(run_js_test '
// Test 1: Single user host — expectedUsers.length < 2, so showUserTable should be false
{
    const data = {
        heart_beat_ts: 1768561603,
        users: {
            nigelleck: { heart_beat_ts: 1768561603, version: "1.0.71" }
        }
    };
    const expectedUsers = getExpectedUsers(data);
    const showUserTable = expectedUsers.length >= 2;
    const pass = !showUserTable && expectedUsers.length === 1;
    console.log("TEST_RESULT:Single user host hides user table:" + (pass ? "PASS" : "FAIL") + ":showUserTable=" + showUserTable + " users=" + expectedUsers.length);
}

// Test 2: Two-user host — showUserTable should be true
{
    const data = {
        heart_beat_ts: 1768565174,
        users: {
            sloth: { heart_beat_ts: 1768565174 },
            rocket: { heart_beat_ts: 1768562003 }
        }
    };
    const expectedUsers = getExpectedUsers(data);
    const showUserTable = expectedUsers.length >= 2;
    const pass = showUserTable && expectedUsers.length === 2;
    console.log("TEST_RESULT:Two-user host shows user table:" + (pass ? "PASS" : "FAIL") + ":showUserTable=" + showUserTable + " users=" + expectedUsers.length);
}

// Test 3: Three-user host — showUserTable should be true
{
    const data = {
        heart_beat_ts: 1768562432,
        users: {
            rocket: { heart_beat_ts: 1768561655 },
            elephant: { heart_beat_ts: 1768560597 },
            sloth: { heart_beat_ts: 1768562432 }
        }
    };
    const expectedUsers = getExpectedUsers(data);
    const showUserTable = expectedUsers.length >= 2;
    const pass = showUserTable && expectedUsers.length === 3;
    console.log("TEST_RESULT:Three-user host shows user table:" + (pass ? "PASS" : "FAIL") + ":showUserTable=" + showUserTable + " users=" + expectedUsers.length);
}

// Test 4: Host with no users — showUserTable should be false
{
    const data = { heart_beat_ts: 1768562432 };
    const expectedUsers = getExpectedUsers(data);
    const showUserTable = expectedUsers.length >= 2;
    const pass = !showUserTable && expectedUsers.length === 0;
    console.log("TEST_RESULT:No-user host hides user table:" + (pass ? "PASS" : "FAIL") + ":showUserTable=" + showUserTable + " users=" + expectedUsers.length);
}

// Test 5: Per-user log URLs are correctly generated
{
    const data = {
        heart_beat_ts: 1768563043,
        users: {
            rocket: { heart_beat_ts: 1768562764 },
            sloth: { heart_beat_ts: 1768563043 }
        }
    };
    const expectedUsers = getExpectedUsers(data);
    const hostname = "GRQ-19";
    const urls = expectedUsers.map(u => {
        const slug = sanitizeUserSlug(u);
        return "./log-viewer.html?file=./" + hostname + "/node-" + slug + ".log";
    });
    const hasRocket = urls.some(u => u.includes("node-rocket.log"));
    const hasSloth = urls.some(u => u.includes("node-sloth.log"));
    const pass = hasRocket && hasSloth && urls.length === 2;
    console.log("TEST_RESULT:Per-user log URLs are correct:" + (pass ? "PASS" : "FAIL") + ":urls=" + JSON.stringify(urls));
}

// Test 6: sanitizeUserSlug handles spaces and special chars
{
    const slug1 = sanitizeUserSlug("john doe");
    const slug2 = sanitizeUserSlug("user@host");
    const slug3 = sanitizeUserSlug("");
    const slug4 = sanitizeUserSlug(null);
    const pass = slug1 === "john_doe" && slug2 === "userhost" && slug3 === "unknown" && slug4 === "unknown";
    console.log("TEST_RESULT:sanitizeUserSlug handles edge cases:" + (pass ? "PASS" : "FAIL") + ":slugs=" + [slug1,slug2,slug3,slug4].join(","));
}
')

while IFS= read -r line; do
    case "$line" in
        TEST_RESULT:*:PASS:*)
            name=$(echo "$line" | cut -d: -f2)
            pass_test "$name"
            ;;
        TEST_RESULT:*:FAIL:*)
            name=$(echo "$line" | cut -d: -f2)
            detail=$(echo "$line" | cut -d: -f4-)
            fail_test "$name ($detail)"
            ;;
    esac
done <<< "$TEST_OUTPUT"

echo ""
echo "================================================"
echo "Test Summary"
echo "================================================"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "Some tests FAILED."
    exit 1
else
    echo "All tests PASSED!"
    exit 0
fi
