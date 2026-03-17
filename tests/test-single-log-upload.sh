#!/bin/bash
# Test for Issue #63: Only upload one log file (per-user log, not node.log)
# Tests that getHostLogFilename() returns the per-user log filename
# instead of the generic node.log.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #63: Single log file upload (per-user log only)"
echo "============================================================="
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
// Test 1: Single-user host returns per-user log filename
{
    const data = {
        users: { score: { heart_beat_ts: 1700000000 } }
    };
    const filename = getHostLogFilename(data);
    if (filename === "node-score.log") {
        console.log("TEST_RESULT:single-user-log:PASS:returns node-score.log for single user");
    } else {
        console.log("TEST_RESULT:single-user-log:FAIL:expected node-score.log, got " + filename);
    }
}

// Test 2: Multi-user host returns null (each user has their own button)
{
    const data = {
        users: {
            alice: { heart_beat_ts: 1700000000 },
            bob:   { heart_beat_ts: 1700000000 }
        }
    };
    const filename = getHostLogFilename(data);
    if (filename === null) {
        console.log("TEST_RESULT:multi-user-log:PASS:returns null for multi-user host");
    } else {
        console.log("TEST_RESULT:multi-user-log:FAIL:expected null, got " + filename);
    }
}

// Test 3: No users map returns null (legacy host with no log)
{
    const data = {};
    const filename = getHostLogFilename(data);
    if (filename === null) {
        console.log("TEST_RESULT:no-users-log:PASS:returns null for host without users map");
    } else {
        console.log("TEST_RESULT:no-users-log:FAIL:expected null, got " + filename);
    }
}

// Test 4: User with spaces in name gets sanitised slug
{
    const data = {
        users: { "my user": { heart_beat_ts: 1700000000 } }
    };
    const filename = getHostLogFilename(data);
    if (filename === "node-my_user.log") {
        console.log("TEST_RESULT:slug-sanitised-log:PASS:spaces sanitised to underscores");
    } else {
        console.log("TEST_RESULT:slug-sanitised-log:FAIL:expected node-my_user.log, got " + filename);
    }
}

// Test 5: Single valid user among invalid entries returns per-user log
{
    const data = {
        users: {
            score: { heart_beat_ts: 1700000000 },
            "": { heart_beat_ts: 1700000000 },
            bob: null
        }
    };
    const filename = getHostLogFilename(data);
    if (filename === "node-score.log") {
        console.log("TEST_RESULT:filtered-single-user:PASS:returns per-user log after filtering invalid entries");
    } else {
        console.log("TEST_RESULT:filtered-single-user:FAIL:expected node-score.log, got " + filename);
    }
}
')

while IFS= read -r line; do
    case "$line" in
        TEST_RESULT:*) check_result "$line" ;;
    esac
done <<< "$OUTPUT"

echo ""
echo "============================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
