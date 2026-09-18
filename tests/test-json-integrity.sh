#!/bin/bash
# Test for Issue #65: health document corruption/removal recovery
# Verifies that run.sh handles a corrupted or missing health document gracefully
#
# Issue #213 moved the document a heartbeat writes from the fleet-wide
# docs/index.json to this host's own docs/host-status/<HOST>.json, so every
# check below now targets that file. The Issue #65 behaviours are unchanged:
# missing, corrupted and empty documents are all recovered, the recovery is
# reported rather than silent, and the result is always valid JSON.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"

echo "Testing Issue #65: health document integrity and recovery"
echo "====================================================="
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

# Create a temporary directory to work in
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# shellcheck source=tests/health-harness.sh
source "$SCRIPT_DIR/health-harness.sh"

# The document a heartbeat writes (Issue #213).
HOST_DOC="docs/host-status/TEST-HOST.json"

# Test 1: Missing host document - should create it fresh
echo "Test 1: Missing host document creates a new file..."
TEST_DIR="${WORK_DIR}/test1"
mkdir -p "$TEST_DIR/docs"
build_health_harness "$TEST_DIR"

cd "$TEST_DIR"
RUN_SH="$RUN_SH" JSON_FILE="docs/index.json" HOSTNAME="TEST-HOST" USER_KEY="testuser" \
    CURRENT_TS="$(date +%s)" bash test_harness.sh 2>&1 || true

if [ -f "$HOST_DOC" ]; then
    if jq . "$HOST_DOC" > /dev/null 2>&1; then
        pass_test "Missing host document: created valid JSON file"
    else
        fail_test "Missing host document: created file but it is invalid JSON"
    fi
else
    fail_test "Missing host document: file was not created"
fi

# Test 2: Corrupted host document - should recover and produce valid output
echo "Test 2: Corrupted host document is detected and recovered..."
TEST_DIR="${WORK_DIR}/test2"
mkdir -p "$TEST_DIR/docs"
build_health_harness "$TEST_DIR"

cd "$TEST_DIR"
# Write corrupted JSON
mkdir -p docs/host-status
echo '{"uptime": 1000, BROKEN' > "$HOST_DOC"

OUTPUT=$(RUN_SH="$RUN_SH" JSON_FILE="docs/index.json" HOSTNAME="TEST-HOST" USER_KEY="testuser" \
    CURRENT_TS="$(date +%s)" bash test_harness.sh 2>&1 || true)

if [ -f "$HOST_DOC" ]; then
    if jq . "$HOST_DOC" > /dev/null 2>&1; then
        pass_test "Corrupted host document: recovered to valid JSON"
    else
        fail_test "Corrupted host document: file is still invalid JSON"
    fi
else
    fail_test "Corrupted host document: file was removed instead of recovered"
fi

# Test 3: Empty host document - should recover
echo "Test 3: Empty host document is handled..."
TEST_DIR="${WORK_DIR}/test3"
mkdir -p "$TEST_DIR/docs"
build_health_harness "$TEST_DIR"

cd "$TEST_DIR"
# Write empty file
mkdir -p docs/host-status
true > "$HOST_DOC"

OUTPUT=$(RUN_SH="$RUN_SH" JSON_FILE="docs/index.json" HOSTNAME="TEST-HOST" USER_KEY="testuser" \
    CURRENT_TS="$(date +%s)" bash test_harness.sh 2>&1 || true)

if [ -f "$HOST_DOC" ]; then
    if jq . "$HOST_DOC" > /dev/null 2>&1; then
        pass_test "Empty host document: recovered to valid JSON"
    else
        fail_test "Empty host document: file is still invalid"
    fi
else
    fail_test "Empty host document: file was removed instead of recovered"
fi

# Test 4: Valid index.json preserves existing hosts
# Issue #213: the other hosts are preserved by not writing the fleet-wide file
# at all, and this host's entry is seeded into its own document.
echo "Test 4: Valid index.json preserves existing hosts..."
TEST_DIR="${WORK_DIR}/test4"
mkdir -p "$TEST_DIR/docs"
build_health_harness "$TEST_DIR"

cd "$TEST_DIR"
cat > docs/index.json << 'EXISTING'
{
  "GRQ-99": {
    "uptime": 5000,
    "location": "Newport Office",
    "emoji": "🍭",
    "heart_beat_ts": 1700000000
  }
}
EXISTING

RUN_SH="$RUN_SH" JSON_FILE="docs/index.json" HOSTNAME="TEST-HOST" USER_KEY="testuser" \
    CURRENT_TS="$(date +%s)" bash test_harness.sh 2>&1 || true

if jq . docs/index.json > /dev/null 2>&1; then
    # Check that GRQ-99 still exists
    if jq -e '.["GRQ-99"]' docs/index.json > /dev/null 2>&1; then
        # Check that TEST-HOST got its own document
        if jq -e '.heart_beat_ts' "$HOST_DOC" > /dev/null 2>&1; then
            pass_test "Valid index.json: existing hosts preserved and new host added"
        else
            fail_test "Valid index.json: new host document was not written"
        fi
    else
        fail_test "Valid index.json: existing host GRQ-99 was lost"
    fi
else
    fail_test "Valid index.json: file became invalid after update"
fi

# Test 5: Post-write JSON has required fields
echo "Test 5: Post-write JSON validation..."
TEST_DIR="${WORK_DIR}/test5"
mkdir -p "$TEST_DIR/docs"
build_health_harness "$TEST_DIR"

cd "$TEST_DIR"
echo '{}' > docs/index.json

RUN_SH="$RUN_SH" JSON_FILE="docs/index.json" HOSTNAME="TEST-HOST" USER_KEY="testuser" \
    CURRENT_TS="$(date +%s)" bash test_harness.sh 2>&1 || true

if jq . "$HOST_DOC" > /dev/null 2>&1; then
    local_ts=$(jq -r '.heart_beat_ts' "$HOST_DOC" 2>/dev/null)
    if [ -n "$local_ts" ] && [ "$local_ts" != "null" ]; then
        pass_test "Post-write validation: JSON is valid with required fields"
    else
        fail_test "Post-write validation: missing heart_beat_ts field"
    fi
else
    fail_test "Post-write validation: output JSON is invalid"
fi

# Test 6: Corruption is reported in output
echo "Test 6: Corruption detected and reported in output..."
TEST_DIR="${WORK_DIR}/test6"
mkdir -p "$TEST_DIR/docs"
build_health_harness "$TEST_DIR"

cd "$TEST_DIR"
mkdir -p docs/host-status
echo 'NOT VALID JSON AT ALL' > "$HOST_DOC"

OUTPUT=$(RUN_SH="$RUN_SH" JSON_FILE="docs/index.json" HOSTNAME="TEST-HOST" USER_KEY="testuser" \
    CURRENT_TS="$(date +%s)" bash test_harness.sh 2>&1 || true)

if echo "$OUTPUT" | grep -qi "corrupt\|invalid\|recover"; then
    pass_test "Corruption detected and reported in output"
else
    fail_test "No corruption warning in output: $OUTPUT"
fi

# Summary
echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
