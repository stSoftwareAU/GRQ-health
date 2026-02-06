#!/bin/bash
# Test script for Issue #26: Last seen an hour ago isn't a critical issue
#
# These are functional "what" tests that call getHealthStatus() with real test
# data and verify the returned status string. They do NOT grep source code.
#
# Key behaviour under test:
# - A multi-user host with a recent host heartbeat but a stale user should be
#   WARNING, not CRITICAL.
# - The host-level heart_beat_ts is used for critical/MIA determination.
# - Per-user stale heartbeats trigger warning status only.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #26: Last seen an hour ago isn't a critical issue"
echo "==============================================================="
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

# Run all tests in a single deno invocation for efficiency.
# The JS code prints lines like "TEST_RESULT:<name>:<PASS|FAIL>:<detail>"
TEST_OUTPUT=$(run_js_test '
const now = Math.floor(Date.now() / 1000);
const oneHourAgo = now - 3600;
const fiveHoursAgo = now - 5 * 3600;
const thirtyHoursAgo = now - 30 * 3600;
const fortyEightHoursAgo = now - 48 * 3600;

// Test 1: Host seen 1 hour ago with one stale user (30h) should be WARNING, not CRITICAL
{
    const data = {
        heart_beat_ts: oneHourAgo,
        os_info: "macOS",
        os_version: "15.0",
        users: {
            sloth: { heart_beat_ts: oneHourAgo },
            rocket: { heart_beat_ts: thirtyHoursAgo }
        }
    };
    const status = getHealthStatus("GRQ-TEST", data);
    const pass = status === "warning";
    console.log("TEST_RESULT:Recent host with stale user is WARNING:" + (pass ? "PASS" : "FAIL") + ":got " + status);
}

// Test 2: Host not seen for 48 hours should be CRITICAL
{
    const data = {
        heart_beat_ts: fortyEightHoursAgo,
        os_info: "macOS",
        os_version: "15.0",
        users: {
            sloth: { heart_beat_ts: fortyEightHoursAgo }
        }
    };
    const status = getHealthStatus("GRQ-TEST2", data);
    const pass = status === "critical";
    console.log("TEST_RESULT:Old host heartbeat is CRITICAL:" + (pass ? "PASS" : "FAIL") + ":got " + status);
}

// Test 3: Host seen 1 hour ago with all users fresh should be HEALTHY
{
    const data = {
        heart_beat_ts: oneHourAgo,
        os_info: "macOS",
        os_version: "15.0",
        users: {
            sloth: { heart_beat_ts: oneHourAgo },
            rocket: { heart_beat_ts: fiveHoursAgo }
        }
    };
    const status = getHealthStatus("GRQ-TEST3", data);
    const pass = status === "healthy";
    console.log("TEST_RESULT:Recent host with fresh users is HEALTHY:" + (pass ? "PASS" : "FAIL") + ":got " + status);
}

// Test 4: Dead machine returns DEAD regardless of heartbeat
{
    const data = {
        death_date: "5 May 2024",
        heart_beat_ts: oneHourAgo
    };
    const status = getHealthStatus("GRQ-DEAD", data);
    const pass = status === "dead";
    console.log("TEST_RESULT:Dead machine is DEAD:" + (pass ? "PASS" : "FAIL") + ":got " + status);
}

// Test 5: Mobile host not seen for 30 hours should be MIA (not CRITICAL)
{
    const data = {
        heart_beat_ts: thirtyHoursAgo,
        mobile: true,
        os_info: "macOS",
        os_version: "15.0"
    };
    const status = getHealthStatus("GRQ-MOBILE", data);
    const pass = status === "mia";
    console.log("TEST_RESULT:Old mobile host is MIA:" + (pass ? "PASS" : "FAIL") + ":got " + status);
}

// Test 6: Host seen 5 hours ago, two users both fresh, should be HEALTHY
{
    const data = {
        heart_beat_ts: fiveHoursAgo,
        os_info: "macOS",
        os_version: "15.0",
        users: {
            elephant: { heart_beat_ts: fiveHoursAgo },
            rocket: { heart_beat_ts: fiveHoursAgo }
        }
    };
    const status = getHealthStatus("GRQ-TEST6", data);
    const pass = status === "healthy";
    console.log("TEST_RESULT:Multi-user host all fresh is HEALTHY:" + (pass ? "PASS" : "FAIL") + ":got " + status);
}
')

# Parse test results
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

# Summary
echo ""
echo "==============================================================="
echo "Test Summary"
echo "==============================================================="
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
