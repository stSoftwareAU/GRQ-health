#!/bin/bash
# Test for Issue #22: Highlight which user has the warning
# Calls getStaleUsers() and buildStaleUserWarning() with test data to verify
# that stale users are correctly identified and warning text is generated.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #22: Stale user highlighting"
echo "==========================================="
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

OUTPUT=$(run_js_test '
const NOW_TS = 1700000000;

// Test 1: Multi-user host with one stale user returns that user
{
    const oneHourAgo = NOW_TS - 3600;
    const twoDaysAgo = NOW_TS - 2 * 86400;
    const data = {
        users: {
            alice: { heart_beat_ts: oneHourAgo },
            bob:   { heart_beat_ts: twoDaysAgo }
        }
    };
    const stale = getStaleUsers(data, NOW_TS);
    if (stale.length === 1 && stale[0].username === "bob") {
        console.log("TEST_RESULT:one-stale:PASS:correctly identified bob as stale");
    } else {
        console.log("TEST_RESULT:one-stale:FAIL:expected [bob], got " + JSON.stringify(stale));
    }
}

// Test 2: Multi-user host with all fresh users returns empty
{
    const oneHourAgo = NOW_TS - 3600;
    const data = {
        users: {
            alice: { heart_beat_ts: oneHourAgo },
            bob:   { heart_beat_ts: oneHourAgo }
        }
    };
    const stale = getStaleUsers(data, NOW_TS);
    if (stale.length === 0) {
        console.log("TEST_RESULT:none-stale:PASS:no stale users detected");
    } else {
        console.log("TEST_RESULT:none-stale:FAIL:expected [], got " + JSON.stringify(stale));
    }
}

// Test 3: Single-user host is always skipped (only check multi-user hosts)
{
    const twoDaysAgo = NOW_TS - 2 * 86400;
    const data = {
        users: {
            alice: { heart_beat_ts: twoDaysAgo }
        }
    };
    const stale = getStaleUsers(data, NOW_TS);
    if (stale.length === 0) {
        console.log("TEST_RESULT:single-user-skip:PASS:single-user host skipped");
    } else {
        console.log("TEST_RESULT:single-user-skip:FAIL:expected [], got " + JSON.stringify(stale));
    }
}

// Test 4: User with no heartbeat is considered stale ("never seen")
{
    const oneHourAgo = NOW_TS - 3600;
    const data = {
        users: {
            alice: { heart_beat_ts: oneHourAgo },
            bob:   {}
        }
    };
    const stale = getStaleUsers(data, NOW_TS);
    if (stale.length === 1 && stale[0].username === "bob" && stale[0].heartbeatTs === 0) {
        console.log("TEST_RESULT:never-seen:PASS:user with no heartbeat is stale");
    } else {
        console.log("TEST_RESULT:never-seen:FAIL:expected bob (never seen), got " + JSON.stringify(stale));
    }
}

// Test 5: buildStaleUserWarning generates correct text for one stale user
{
    const oneHourAgo = NOW_TS - 3600;
    const twoDaysAgo = NOW_TS - 2 * 86400;
    const data = {
        users: {
            alice: { heart_beat_ts: oneHourAgo },
            bob:   { heart_beat_ts: twoDaysAgo }
        }
    };
    const warning = buildStaleUserWarning(data, NOW_TS);
    if (warning.includes("Stale user:") && warning.includes("bob")) {
        console.log("TEST_RESULT:warning-singular:PASS:singular warning text correct");
    } else {
        console.log("TEST_RESULT:warning-singular:FAIL:got: " + warning);
    }
}

// Test 6: buildStaleUserWarning generates plural text for multiple stale users
{
    const twoDaysAgo = NOW_TS - 2 * 86400;
    const data = {
        users: {
            alice: { heart_beat_ts: twoDaysAgo },
            bob:   { heart_beat_ts: twoDaysAgo }
        }
    };
    const warning = buildStaleUserWarning(data, NOW_TS);
    if (warning.includes("Stale users:") && warning.includes("alice") && warning.includes("bob")) {
        console.log("TEST_RESULT:warning-plural:PASS:plural warning text correct");
    } else {
        console.log("TEST_RESULT:warning-plural:FAIL:got: " + warning);
    }
}

// Test 7: buildStaleUserWarning returns empty for no stale users
{
    const oneHourAgo = NOW_TS - 3600;
    const data = {
        users: {
            alice: { heart_beat_ts: oneHourAgo },
            bob:   { heart_beat_ts: oneHourAgo }
        }
    };
    const warning = buildStaleUserWarning(data, NOW_TS);
    if (warning === "") {
        console.log("TEST_RESULT:no-warning:PASS:empty warning for fresh users");
    } else {
        console.log("TEST_RESULT:no-warning:FAIL:expected empty, got: " + warning);
    }
}

// Test 8: buildStaleUserWarning includes "never seen" for missing heartbeat
{
    const oneHourAgo = NOW_TS - 3600;
    const data = {
        users: {
            alice: { heart_beat_ts: oneHourAgo },
            bob:   {}
        }
    };
    const warning = buildStaleUserWarning(data, NOW_TS);
    if (warning.includes("never seen")) {
        console.log("TEST_RESULT:never-seen-text:PASS:warning includes never seen");
    } else {
        console.log("TEST_RESULT:never-seen-text:FAIL:got: " + warning);
    }
}
')

while IFS= read -r line; do
    case "$line" in
        TEST_RESULT:*) check_result "$line" ;;
    esac
done <<< "$OUTPUT"

echo ""
echo "==========================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
