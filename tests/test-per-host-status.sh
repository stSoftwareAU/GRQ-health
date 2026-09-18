#!/bin/bash
# Test for Issue #213: a heartbeat must rewrite one small per-host document
# instead of the fleet-wide docs/index.json.
#
# run.sh now writes docs/host-status/<HOST>.json (this host only) plus a small
# manifest, and leaves the legacy fleet-wide docs/index.json untouched. These
# tests drive the real update_json/seed/manifest functions extracted from
# run.sh and assert on the files they produce.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"

echo "Testing Issue #213: per-host status documents"
echo "============================================="
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

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# shellcheck source=tests/health-harness.sh
source "$SCRIPT_DIR/health-harness.sh"

# Build a legacy fleet-wide index.json with many hosts, as the fleet has today.
write_legacy_index() {
    local target="$1"
    local hosts=(GRQ-3 GRQ-7 GRQ-10 GRQ-11 GRQ-12 GRQ-13 GRQ-15 GRQ-16 TEST-HOST Mac-Ultra-M2 oracle-3 selenium4)
    local body="{}"
    local host
    for host in "${hosts[@]}"; do
        body=$(printf '%s' "$body" | jq --arg h "$host" '
            .[$h] = {
                uptime: 4037305,
                free_disk_space: "76",
                mem_usage_percent: "10.1",
                cpu_load: "186.0%",
                timezone: "AEST",
                os_info: "macOS",
                os_version: "26.6",
                network_status: "connected",
                heart_beat_ts: 1700000000,
                location: "Newport Office",
                emoji: "👌",
                used_disk_percent: "60.4",
                total_disk_gb: "228",
                cpu_breakdown: "87.67% user, 12.32% sys, 0.0% idle",
                load_averages: "153.5% (1m), 184.7% (5m), 186.0% (15m)",
                ip_addresses: "WiFi: 10.0.0.151, Eth: 10.0.0.10",
                version: "1.1.28",
                users: { sloth: { heart_beat_ts: 1700000000, version: "1.1.28" } },
                user_count: 1
            }')
    done
    printf '%s\n' "$body" > "$target"
}

# ---------------------------------------------------------------------------
# Test 1: a heartbeat creates the per-host document and the manifest
# ---------------------------------------------------------------------------
echo "Test 1: heartbeat writes docs/host-status/<HOST>.json and a manifest..."
TEST_DIR="${WORK_DIR}/test1"
mkdir -p "$TEST_DIR/docs"
build_health_harness "$TEST_DIR"
run_health_harness "$TEST_DIR" HOSTNAME="TEST-HOST" USER_KEY="testuser" CURRENT_TS="1700000100" > /dev/null
if [ "$LAST_HARNESS_STATUS" = "0" ]; then
    pass_test "heartbeat exits 0"
else
    fail_test "heartbeat exited $LAST_HARNESS_STATUS"
fi

HOST_DOC="$TEST_DIR/docs/host-status/TEST-HOST.json"
MANIFEST="$TEST_DIR/docs/host-status/index.json"
if [ -f "$HOST_DOC" ] && jq . "$HOST_DOC" > /dev/null 2>&1; then
    pass_test "per-host document created and valid JSON"
else
    fail_test "per-host document missing or invalid at docs/host-status/TEST-HOST.json"
fi

if [ -f "$HOST_DOC" ] && [ "$(jq -r '.host' "$HOST_DOC")" = "TEST-HOST" ]; then
    pass_test "per-host document names its host"
else
    fail_test "per-host document does not carry host=TEST-HOST"
fi

if [ -f "$HOST_DOC" ] && [ "$(jq -r '.users.testuser.heart_beat_ts' "$HOST_DOC")" = "1700000100" ]; then
    pass_test "per-user heartbeat recorded in the per-host document"
else
    fail_test "per-user heartbeat not recorded in the per-host document"
fi

if [ -f "$MANIFEST" ] && jq -e '.hosts | index("TEST-HOST")' "$MANIFEST" > /dev/null 2>&1; then
    pass_test "manifest lists the host"
else
    fail_test "manifest missing or does not list TEST-HOST"
fi

# ---------------------------------------------------------------------------
# Test 2: the fleet-wide index.json is no longer rewritten by a heartbeat
# ---------------------------------------------------------------------------
echo "Test 2: a heartbeat leaves the fleet-wide index.json byte-identical..."
TEST_DIR="${WORK_DIR}/test2"
mkdir -p "$TEST_DIR/docs"
build_health_harness "$TEST_DIR"
write_legacy_index "$TEST_DIR/docs/index.json"
BEFORE_SUM=$(cksum < "$TEST_DIR/docs/index.json")
run_health_harness "$TEST_DIR" HOSTNAME="TEST-HOST" USER_KEY="testuser" CURRENT_TS="1700000200" > /dev/null
AFTER_SUM=$(cksum < "$TEST_DIR/docs/index.json")

if [ "$BEFORE_SUM" = "$AFTER_SUM" ]; then
    pass_test "docs/index.json untouched by the heartbeat"
else
    fail_test "docs/index.json was rewritten by the heartbeat"
fi

HOST_DOC="$TEST_DIR/docs/host-status/TEST-HOST.json"
LEGACY_BYTES=$(wc -c < "$TEST_DIR/docs/index.json" | tr -d ' ')
HOST_BYTES=$(wc -c < "$HOST_DOC" | tr -d ' ')
if [ "$HOST_BYTES" -lt "$((LEGACY_BYTES / 4))" ]; then
    pass_test "per-host document (${HOST_BYTES}B) is far smaller than the fleet document (${LEGACY_BYTES}B)"
else
    fail_test "per-host document (${HOST_BYTES}B) is not materially smaller than the fleet document (${LEGACY_BYTES}B)"
fi

# ---------------------------------------------------------------------------
# Test 3: migration — the first per-host write seeds from the legacy entry
# ---------------------------------------------------------------------------
echo "Test 3: first per-host write seeds manual fields from the legacy entry..."
if [ "$(jq -r '.location' "$HOST_DOC")" = "Newport Office" ] && [ "$(jq -r '.emoji' "$HOST_DOC")" = "👌" ]; then
    pass_test "manual fields (location, emoji) carried over from docs/index.json"
else
    fail_test "manual fields were lost during migration to the per-host document"
fi

if [ "$(jq -r '.users.sloth.heart_beat_ts' "$HOST_DOC")" = "1700000000" ]; then
    pass_test "other users' heartbeats carried over from docs/index.json"
else
    fail_test "other users' heartbeats were lost during migration"
fi

if [ "$(jq -r '.users | keys | length' "$HOST_DOC")" = "2" ]; then
    pass_test "seeded document holds both the migrated and the current user"
else
    fail_test "seeded document does not hold both users"
fi

# Another host's entry must never leak into this host's document.
if jq -e 'has("GRQ-3") | not' "$HOST_DOC" > /dev/null 2>&1; then
    pass_test "per-host document holds only this host"
else
    fail_test "per-host document leaked another host's entry"
fi

# ---------------------------------------------------------------------------
# Test 4: a second heartbeat updates in place and preserves manual fields
# ---------------------------------------------------------------------------
echo "Test 4: a later heartbeat updates in place..."
run_health_harness "$TEST_DIR" HOSTNAME="TEST-HOST" USER_KEY="testuser" CURRENT_TS="1700009999" > /dev/null
if [ "$(jq -r '.users.testuser.heart_beat_ts' "$HOST_DOC")" = "1700009999" ] \
    && [ "$(jq -r '.location' "$HOST_DOC")" = "Newport Office" ]; then
    pass_test "heartbeat refreshed and manual fields preserved"
else
    fail_test "second heartbeat lost the timestamp or the manual fields"
fi

if [ "$(jq -r '.heart_beat_ts' "$HOST_DOC")" = "1700009999" ]; then
    pass_test "host heartbeat aggregates to the newest user heartbeat"
else
    fail_test "host heart_beat_ts did not aggregate to the newest user heartbeat"
fi

# ---------------------------------------------------------------------------
# Test 5: corrupted per-host document recovers, with no debris under docs/
# ---------------------------------------------------------------------------
echo "Test 5: corrupted per-host document is recovered..."
TEST_DIR="${WORK_DIR}/test5"
mkdir -p "$TEST_DIR/docs/host-status"
build_health_harness "$TEST_DIR"
echo '{"uptime": 1000, BROKEN' > "$TEST_DIR/docs/host-status/TEST-HOST.json"
OUTPUT=$(run_health_harness "$TEST_DIR" HOSTNAME="TEST-HOST" USER_KEY="testuser" CURRENT_TS="1700000300" || true)

if jq . "$TEST_DIR/docs/host-status/TEST-HOST.json" > /dev/null 2>&1; then
    pass_test "corrupted per-host document recovered to valid JSON"
else
    fail_test "corrupted per-host document is still invalid"
fi

if echo "$OUTPUT" | grep -qi "corrupt"; then
    pass_test "corruption reported on stdout (fails loud)"
else
    fail_test "corruption was recovered silently"
fi

DEBRIS=$(find "$TEST_DIR/docs" -name '*.bak' -o -name '*.corrupted.*' -o -name '*.tmp*' | wc -l | tr -d ' ')
if [ "$DEBRIS" = "0" ]; then
    pass_test "no backup/temporary debris left under docs/"
else
    fail_test "recovery left $DEBRIS backup/temporary files under docs/ (they would be committed)"
fi

# ---------------------------------------------------------------------------
# Test 6: the manifest keeps other hosts and is only rewritten when it changes
# ---------------------------------------------------------------------------
echo "Test 6: manifest is stable and preserves other hosts..."
TEST_DIR="${WORK_DIR}/test6"
mkdir -p "$TEST_DIR/docs/host-status"
build_health_harness "$TEST_DIR"
echo '{"host":"GRQ-99","heart_beat_ts":1699999999}' > "$TEST_DIR/docs/host-status/GRQ-99.json"
run_health_harness "$TEST_DIR" HOSTNAME="TEST-HOST" USER_KEY="testuser" CURRENT_TS="1700000400" > /dev/null
MANIFEST="$TEST_DIR/docs/host-status/index.json"

if [ "$(jq -c '.hosts' "$MANIFEST")" = '["GRQ-99","TEST-HOST"]' ]; then
    pass_test "manifest lists every host document, sorted"
else
    fail_test "manifest is wrong: $(jq -c '.hosts' "$MANIFEST" 2>/dev/null)"
fi

MANIFEST_SUM_BEFORE=$(cksum < "$MANIFEST")
run_health_harness "$TEST_DIR" HOSTNAME="TEST-HOST" USER_KEY="testuser" CURRENT_TS="1700000500" > /dev/null
MANIFEST_SUM_AFTER=$(cksum < "$MANIFEST")
if [ "$MANIFEST_SUM_BEFORE" = "$MANIFEST_SUM_AFTER" ]; then
    pass_test "manifest not rewritten when the host list is unchanged"
else
    fail_test "manifest rewritten on every heartbeat (needless commit churn)"
fi

# ---------------------------------------------------------------------------
# Test 7: a hostile hostname cannot escape docs/host-status/
# ---------------------------------------------------------------------------
echo "Test 7: hostname is sanitised into a bare filename..."
TEST_DIR="${WORK_DIR}/test7"
mkdir -p "$TEST_DIR/docs/host-status"
# The call is appended to the harness verbatim, so it must stay unexpanded here.
# shellcheck disable=SC2016
build_health_harness "$TEST_DIR" 'host_slug "$HOSTNAME"'
SLUG=$(run_health_harness "$TEST_DIR" HOSTNAME="../../etc/passwd" USER_KEY="testuser")
case "$SLUG" in
    */*|*..*|"")
        fail_test "hostname '../../etc/passwd' produced unsafe slug '$SLUG'"
        ;;
    *)
        pass_test "hostname '../../etc/passwd' sanitised to '$SLUG'"
        ;;
esac

SLUG=$(run_health_harness "$TEST_DIR" HOSTNAME=".hidden" USER_KEY="testuser")
case "$SLUG" in
    .*)
        fail_test "hostname '.hidden' produced a hidden filename '$SLUG'"
        ;;
    *)
        pass_test "hostname '.hidden' sanitised to '$SLUG'"
        ;;
esac

SLUG=$(run_health_harness "$TEST_DIR" HOSTNAME="GRQ-10" USER_KEY="testuser")
if [ "$SLUG" = "GRQ-10" ]; then
    pass_test "ordinary hostname passes through unchanged"
else
    fail_test "ordinary hostname 'GRQ-10' was mangled to '$SLUG'"
fi

# The dashboard rejects any manifest entry that does not match
# SAFE_HOST_NAME in docs/host-status.js, so a slug run.sh can emit but the
# dashboard refuses is a host that silently disappears. Assert the producer
# stays inside the consumer's grammar.
SAFE_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
for raw in "../../etc/passwd" ".hidden" "-weird" "_build" "GRQ-10" "Tinas MacBook Air" \
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "!!!"; do
    SLUG=$(run_health_harness "$TEST_DIR" HOSTNAME="$raw" USER_KEY="testuser")
    if printf '%s' "$SLUG" | grep -Eq "$SAFE_RE"; then
        pass_test "slug for '$raw' ('$SLUG') is accepted by the dashboard validator"
    else
        fail_test "slug for '$raw' ('$SLUG') would be rejected by the dashboard validator"
    fi
done

# ---------------------------------------------------------------------------
# Test 8: a heartbeat that cannot write fails loud
# ---------------------------------------------------------------------------
echo "Test 8: a failed write is reported and exits non-zero..."
TEST_DIR="${WORK_DIR}/test8"
mkdir -p "$TEST_DIR/docs"
# Break get_system_info so the jq update cannot run — this is how a missing
# dependency corrupts the captured JSON in practice.
# shellcheck disable=SC2016
build_health_harness "$TEST_DIR" 'get_system_info() { echo "not json at all"; }
update_json'
OUTPUT=$(run_health_harness "$TEST_DIR" HOSTNAME="TEST-HOST" USER_KEY="testuser" CURRENT_TS="1700000600") \
    && HARNESS_STATUS=0 || HARNESS_STATUS=$?

if [ "$HARNESS_STATUS" != "0" ]; then
    pass_test "failed write exits non-zero"
else
    fail_test "failed write reported success (exit $HARNESS_STATUS)"
fi

if echo "$OUTPUT" | grep -q "ERROR"; then
    pass_test "failed write reports an error"
else
    fail_test "failed write produced no error message: $OUTPUT"
fi

if ! echo "$OUTPUT" | grep -q "Updated health information"; then
    pass_test "failed write does not claim the health information was updated"
else
    fail_test "failed write still claimed success"
fi

echo ""
echo "============================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
