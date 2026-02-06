#!/bin/bash
# Test for Issue #13: Per-user log button behaviour
# Calls getExpectedUsers() and getUserEntries() with test data to verify
# that multi-user host detection works correctly (drives button visibility).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #13: Per-user log button logic"
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

OUTPUT=$(run_js_test '
// Test 1: Single-user host — showUserTable should be false (< 2 users)
{
    const data = {
        users: { alice: { heart_beat_ts: 1700000000 } }
    };
    const users = getExpectedUsers(data);
    const showUserTable = users.length >= 2;
    if (!showUserTable) {
        console.log("TEST_RESULT:single-user-no-table:PASS:single user does not trigger user table");
    } else {
        console.log("TEST_RESULT:single-user-no-table:FAIL:expected no table, got " + users.length + " users");
    }
}

// Test 2: Multi-user host (2+ users) — showUserTable should be true
{
    const data = {
        users: {
            alice: { heart_beat_ts: 1700000000 },
            bob:   { heart_beat_ts: 1700000000 }
        }
    };
    const users = getExpectedUsers(data);
    const showUserTable = users.length >= 2;
    if (showUserTable) {
        console.log("TEST_RESULT:multi-user-table:PASS:two users triggers user table");
    } else {
        console.log("TEST_RESULT:multi-user-table:FAIL:expected table, got " + users.length + " users");
    }
}

// Test 3: No users map — should return empty list
{
    const data = {};
    const users = getExpectedUsers(data);
    if (users.length === 0) {
        console.log("TEST_RESULT:no-users-empty:PASS:no users map returns empty list");
    } else {
        console.log("TEST_RESULT:no-users-empty:FAIL:expected 0 users, got " + users.length);
    }
}

// Test 4: getUserEntries filters out invalid entries
{
    const data = {
        users: {
            alice: { heart_beat_ts: 1700000000 },
            "": { heart_beat_ts: 1700000000 },
            bob: null
        }
    };
    const entries = getUserEntries(data);
    if (entries.length === 1 && entries[0][0] === "alice") {
        console.log("TEST_RESULT:filter-invalid:PASS:invalid entries filtered out");
    } else {
        console.log("TEST_RESULT:filter-invalid:FAIL:expected 1 valid entry, got " + entries.length);
    }
}

// Test 5: sanitizeUserSlug produces valid slugs
{
    const slug1 = sanitizeUserSlug("my user");
    const slug2 = sanitizeUserSlug(null);
    const slug3 = sanitizeUserSlug("alice");
    const ok = slug1 === "my_user" && slug2 === "unknown" && slug3 === "alice";
    if (ok) {
        console.log("TEST_RESULT:slug-sanitise:PASS:slugs are correct");
    } else {
        console.log("TEST_RESULT:slug-sanitise:FAIL:got " + slug1 + ", " + slug2 + ", " + slug3);
    }
}

// Test 6: getExpectedUsers returns sorted list
{
    const data = {
        users: {
            charlie: { heart_beat_ts: 1700000000 },
            alice:   { heart_beat_ts: 1700000000 },
            bob:     { heart_beat_ts: 1700000000 }
        }
    };
    const users = getExpectedUsers(data);
    const sorted = users.join(",") === "alice,bob,charlie";
    if (sorted) {
        console.log("TEST_RESULT:sorted-users:PASS:users are alphabetically sorted");
    } else {
        console.log("TEST_RESULT:sorted-users:FAIL:got " + users.join(","));
    }
}
')

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
