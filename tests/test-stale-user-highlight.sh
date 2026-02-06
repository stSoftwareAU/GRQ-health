#!/bin/bash
# Test for Issue #22: Highlight which user has the warning
#
# These are functional "what" tests that call getStaleUsers() and
# buildStaleUserWarning() with real test data and verify the results.
# They do NOT grep source code.
#
# Key behaviour under test:
# - getStaleUsers identifies which specific users are stale on multi-user hosts
# - buildStaleUserWarning generates human-readable warning text
# - Single-user hosts do not trigger stale user warnings
# - Missing heartbeat shows "never seen"
# - Singular/plural grammar is correct

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #22: Stale user highlighting in warnings"
echo "======================================================="
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
const now = Math.floor(Date.now() / 1000);
const fiveHoursAgo = now - 5 * 3600;
const tenHoursAgo = now - 10 * 3600;
const thirtyHoursAgo = now - 30 * 3600;
const fortyHoursAgo = now - 40 * 3600;
const sixtyHoursAgo = now - 60 * 3600;

// Test 1: Single stale user should be identified by name
{
    const data = {
        users: {
            elephant: { heart_beat_ts: thirtyHoursAgo },
            rocket: { heart_beat_ts: fiveHoursAgo }
        }
    };
    const staleUsers = getStaleUsers(data, now);
    const warning = buildStaleUserWarning(data, now);
    const hasElephant = staleUsers.some(u => u.username === "elephant");
    const noRocket = !staleUsers.some(u => u.username === "rocket");
    const warningHasElephant = warning.includes("elephant");
    const pass = hasElephant && noRocket && warningHasElephant;
    console.log("TEST_RESULT:Single stale user identified:" + (pass ? "PASS" : "FAIL") + ":stale=" + staleUsers.map(u=>u.username).join(","));
}

// Test 2: Multiple stale users should all be listed
{
    const data = {
        users: {
            elephant: { heart_beat_ts: thirtyHoursAgo },
            sloth: { heart_beat_ts: fortyHoursAgo },
            rocket: { heart_beat_ts: fiveHoursAgo }
        }
    };
    const staleUsers = getStaleUsers(data, now);
    const warning = buildStaleUserWarning(data, now);
    const hasElephant = staleUsers.some(u => u.username === "elephant");
    const hasSloth = staleUsers.some(u => u.username === "sloth");
    const noRocket = !staleUsers.some(u => u.username === "rocket");
    const pass = hasElephant && hasSloth && noRocket;
    console.log("TEST_RESULT:Multiple stale users listed:" + (pass ? "PASS" : "FAIL") + ":stale=" + staleUsers.map(u=>u.username).join(","));
}

// Test 3: Warning includes relative time info
{
    const data = {
        users: {
            elephant: { heart_beat_ts: thirtyHoursAgo },
            rocket: { heart_beat_ts: fiveHoursAgo }
        }
    };
    const warning = buildStaleUserWarning(data, now);
    const hasTimeInfo = warning.includes("ago") || warning.includes("never");
    const pass = hasTimeInfo;
    console.log("TEST_RESULT:Warning includes time info:" + (pass ? "PASS" : "FAIL") + ":warning=" + warning);
}

// Test 4: No stale users returns empty warning
{
    const data = {
        users: {
            elephant: { heart_beat_ts: fiveHoursAgo },
            rocket: { heart_beat_ts: tenHoursAgo }
        }
    };
    const staleUsers = getStaleUsers(data, now);
    const warning = buildStaleUserWarning(data, now);
    const pass = staleUsers.length === 0 && warning === "";
    console.log("TEST_RESULT:No stale users returns empty:" + (pass ? "PASS" : "FAIL") + ":count=" + staleUsers.length);
}

// Test 5: Single-user host does not check for stale users
{
    const data = {
        users: {
            elephant: { heart_beat_ts: thirtyHoursAgo }
        }
    };
    const staleUsers = getStaleUsers(data, now);
    const warning = buildStaleUserWarning(data, now);
    const pass = staleUsers.length === 0 && warning === "";
    console.log("TEST_RESULT:Single-user host skips stale check:" + (pass ? "PASS" : "FAIL") + ":count=" + staleUsers.length);
}

// Test 6: Missing heartbeat shows "never seen"
{
    const data = {
        users: {
            elephant: {},
            rocket: { heart_beat_ts: fiveHoursAgo }
        }
    };
    const staleUsers = getStaleUsers(data, now);
    const warning = buildStaleUserWarning(data, now);
    const hasElephant = staleUsers.some(u => u.username === "elephant");
    const hasNeverSeen = warning.includes("never seen");
    const pass = hasElephant && hasNeverSeen;
    console.log("TEST_RESULT:Missing heartbeat shows never seen:" + (pass ? "PASS" : "FAIL") + ":warning=" + warning);
}

// Test 7: Custom stale threshold is respected
{
    const data = {
        user_stale_hours: 48,
        users: {
            elephant: { heart_beat_ts: thirtyHoursAgo },
            sloth: { heart_beat_ts: sixtyHoursAgo }
        }
    };
    const staleUsers = getStaleUsers(data, now);
    const noElephant = !staleUsers.some(u => u.username === "elephant");
    const hasSloth = staleUsers.some(u => u.username === "sloth");
    const pass = noElephant && hasSloth;
    console.log("TEST_RESULT:Custom threshold respected:" + (pass ? "PASS" : "FAIL") + ":stale=" + staleUsers.map(u=>u.username).join(","));
}

// Test 8: Singular "user" for one stale user
{
    const data = {
        users: {
            elephant: { heart_beat_ts: thirtyHoursAgo },
            rocket: { heart_beat_ts: fiveHoursAgo }
        }
    };
    const warning = buildStaleUserWarning(data, now);
    const pass = warning.startsWith("Stale user:");
    console.log("TEST_RESULT:Singular grammar for one stale user:" + (pass ? "PASS" : "FAIL") + ":warning=" + warning.substring(0, 20));
}

// Test 9: Plural "users" for multiple stale users
{
    const data = {
        users: {
            elephant: { heart_beat_ts: thirtyHoursAgo },
            sloth: { heart_beat_ts: fortyHoursAgo }
        }
    };
    const warning = buildStaleUserWarning(data, now);
    const pass = warning.startsWith("Stale users:");
    console.log("TEST_RESULT:Plural grammar for multiple stale users:" + (pass ? "PASS" : "FAIL") + ":warning=" + warning.substring(0, 20));
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
echo "======================================================="
echo "Test Summary"
echo "======================================================="
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
