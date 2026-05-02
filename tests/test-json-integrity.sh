#!/bin/bash
# Test for Issue #65: Index.json corruption/removal recovery
# Verifies that run.sh handles corrupted or missing index.json gracefully

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"

echo "Testing Issue #65: Index.json integrity and recovery"
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

# Build a self-contained test harness that sources update_json from run.sh
build_harness() {
    local dir="$1"
    cat > "${dir}/test_harness.sh" << 'HARNESS_EOF'
#!/bin/bash
set -euo pipefail

# Minimal stubs for testing update_json in isolation
HOSTNAME="${HOSTNAME:-TEST-HOST}"
USER_KEY="${USER_KEY:-testuser}"
CURRENT_TS="${CURRENT_TS:-1700000000}"
VERSION="1.0.90"
USER_STALE_HOURS="${USER_STALE_HOURS:-24}"
JSON_FILE="${JSON_FILE:-docs/index.json}"

# Minimal get_system_info that returns valid JSON
get_system_info() {
    cat << 'SYSINFO'
{
    "uptime": 1000,
    "free_disk_space": "100",
    "disk_usage_percent": "20.0",
    "mem_usage_percent": "10.0",
    "cpu_load": "5.0%",
    "timezone": "AEST",
    "os_info": "macOS",
    "os_version": "15.0",
    "network_status": "connected",
    "total_mem_gb": "16",
    "cpu_cores": "8",
    "total_disk_gb": "500",
    "used_disk_percent": "20.0",
    "cpu_breakdown": "5% user, 3% sys, 92% idle",
    "load_averages": "5.0% (1m), 4.0% (5m), 3.0% (15m)",
    "cpu_model": "M4",
    "exception_count": 0,
    "exception_summary": "No errors found",
    "machine_type": "Mac mini",
    "ip_addresses": "WiFi: 10.0.0.1",
    "config_warning": ""
}
SYSINFO
}

HARNESS_EOF
    # Extract update_json function from run.sh (between the two function comments)
    sed -n '/^# Function to update JSON file/,/^# Function to commit/{ /^# Function to commit/d; p; }' "$RUN_SH" >> "${dir}/test_harness.sh"
    # Call update_json at the end
    echo 'update_json' >> "${dir}/test_harness.sh"
    chmod +x "${dir}/test_harness.sh"
}

# Test 1: Missing index.json - should create it fresh
echo "Test 1: Missing index.json creates a new file..."
TEST_DIR="${WORK_DIR}/test1"
mkdir -p "$TEST_DIR/docs"
build_harness "$TEST_DIR"

cd "$TEST_DIR"
RUN_SH="$RUN_SH" JSON_FILE="docs/index.json" HOSTNAME="TEST-HOST" USER_KEY="testuser" \
    CURRENT_TS="$(date +%s)" bash test_harness.sh 2>&1 || true

if [ -f "docs/index.json" ]; then
    if jq . docs/index.json > /dev/null 2>&1; then
        pass_test "Missing index.json: created valid JSON file"
    else
        fail_test "Missing index.json: created file but it is invalid JSON"
    fi
else
    fail_test "Missing index.json: file was not created"
fi

# Test 2: Corrupted index.json - should recover and produce valid output
echo "Test 2: Corrupted index.json is detected and recovered..."
TEST_DIR="${WORK_DIR}/test2"
mkdir -p "$TEST_DIR/docs"
build_harness "$TEST_DIR"

cd "$TEST_DIR"
# Write corrupted JSON
echo '{"GRQ-1": {"uptime": 1000, BROKEN' > docs/index.json

OUTPUT=$(RUN_SH="$RUN_SH" JSON_FILE="docs/index.json" HOSTNAME="TEST-HOST" USER_KEY="testuser" \
    CURRENT_TS="$(date +%s)" bash test_harness.sh 2>&1 || true)

if [ -f "docs/index.json" ]; then
    if jq . docs/index.json > /dev/null 2>&1; then
        pass_test "Corrupted index.json: recovered to valid JSON"
    else
        fail_test "Corrupted index.json: file is still invalid JSON"
    fi
else
    fail_test "Corrupted index.json: file was removed instead of recovered"
fi

# Test 3: Empty index.json - should recover
echo "Test 3: Empty index.json is handled..."
TEST_DIR="${WORK_DIR}/test3"
mkdir -p "$TEST_DIR/docs"
build_harness "$TEST_DIR"

cd "$TEST_DIR"
# Write empty file
true > docs/index.json

OUTPUT=$(RUN_SH="$RUN_SH" JSON_FILE="docs/index.json" HOSTNAME="TEST-HOST" USER_KEY="testuser" \
    CURRENT_TS="$(date +%s)" bash test_harness.sh 2>&1 || true)

if [ -f "docs/index.json" ]; then
    if jq . docs/index.json > /dev/null 2>&1; then
        pass_test "Empty index.json: recovered to valid JSON"
    else
        fail_test "Empty index.json: file is still invalid"
    fi
else
    fail_test "Empty index.json: file was removed instead of recovered"
fi

# Test 4: Valid index.json preserves existing hosts
echo "Test 4: Valid index.json preserves existing hosts..."
TEST_DIR="${WORK_DIR}/test4"
mkdir -p "$TEST_DIR/docs"
build_harness "$TEST_DIR"

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
        # Check that TEST-HOST was added
        if jq -e '.["TEST-HOST"]' docs/index.json > /dev/null 2>&1; then
            pass_test "Valid index.json: existing hosts preserved and new host added"
        else
            fail_test "Valid index.json: new host was not added"
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
build_harness "$TEST_DIR"

cd "$TEST_DIR"
echo '{}' > docs/index.json

RUN_SH="$RUN_SH" JSON_FILE="docs/index.json" HOSTNAME="TEST-HOST" USER_KEY="testuser" \
    CURRENT_TS="$(date +%s)" bash test_harness.sh 2>&1 || true

if jq . docs/index.json > /dev/null 2>&1; then
    local_ts=$(jq -r '.["TEST-HOST"].heart_beat_ts' docs/index.json 2>/dev/null)
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
build_harness "$TEST_DIR"

cd "$TEST_DIR"
echo 'NOT VALID JSON AT ALL' > docs/index.json

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
