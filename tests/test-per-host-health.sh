#!/bin/bash
# Test for Issue #140: per-host health files remove Develop-branch push
# contention.
#
# Covers the write path (helpers/repos.sh writes docs/hosts/<slug>.json plus an
# append-only manifest docs/hosts/index.json) and the read path (dashboard.js
# mergeHostRecords merges the per-host files at render time).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_SCRIPT="$SCRIPT_DIR/../helpers/repos.sh"
# shellcheck source=./extract-functions.sh
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #140: per-host health files"
echo "========================================="
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

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

setup_test_env() {
    local test_dir="$TMPDIR_BASE/test_$$_$RANDOM"
    mkdir -p "$test_dir/docs/hosts" "$test_dir/helpers"
    cp "$REPOS_SCRIPT" "$test_dir/helpers/repos.sh"
    if [ -f "$SCRIPT_DIR/../helpers/git-retry.sh" ]; then
        cp "$SCRIPT_DIR/../helpers/git-retry.sh" "$test_dir/helpers/git-retry.sh"
    fi
    chmod +x "$test_dir/helpers/repos.sh"
    echo "$test_dir"
}

# --------------------------------------------------------------------------
# Test 1: A new host writes its own file and registers itself in the manifest.
# --------------------------------------------------------------------------
echo "Test 1: new host writes docs/hosts/<slug>.json + manifest..."
TEST_DIR=$(setup_test_env)

bash "$TEST_DIR/helpers/repos.sh" --dry-run --skip-rate-limit --project-root "$TEST_DIR" "Vibe Coder:GRQ-23" 2>/dev/null

HOST_FILE="$TEST_DIR/docs/hosts/Vibe-Coder-GRQ-23.json"
if [ -f "$HOST_FILE" ] && [ "$(jq -r '.name' "$HOST_FILE")" = "Vibe Coder:GRQ-23" ]; then
    pass_test "per-host file created with authoritative name"
else
    fail_test "per-host file missing or wrong name"
fi

if [ "$(jq -r '.hosts | index("Vibe-Coder-GRQ-23")' "$TEST_DIR/docs/hosts/index.json")" != "null" ]; then
    pass_test "host slug registered in manifest"
else
    fail_test "host slug not registered in manifest"
fi

# --------------------------------------------------------------------------
# Test 2: Two different hosts never share a file; both appear in the manifest.
# --------------------------------------------------------------------------
echo "Test 2: two hosts get independent files + manifest entries..."
TEST_DIR=$(setup_test_env)

bash "$TEST_DIR/helpers/repos.sh" --dry-run --skip-rate-limit --project-root "$TEST_DIR" "GRQ-A" 2>/dev/null
bash "$TEST_DIR/helpers/repos.sh" --dry-run --skip-rate-limit --project-root "$TEST_DIR" "GRQ-B" 2>/dev/null

if [ -f "$TEST_DIR/docs/hosts/GRQ-A.json" ] && [ -f "$TEST_DIR/docs/hosts/GRQ-B.json" ]; then
    pass_test "each host wrote its own file (no shared file)"
else
    fail_test "expected a separate file per host"
fi

MANIFEST_COUNT=$(jq '.hosts | length' "$TEST_DIR/docs/hosts/index.json")
if [ "$MANIFEST_COUNT" -eq 2 ]; then
    pass_test "manifest lists both hosts ($MANIFEST_COUNT)"
else
    fail_test "manifest should list 2 hosts (got: $MANIFEST_COUNT)"
fi

# --------------------------------------------------------------------------
# Test 3: Re-running an existing host does NOT duplicate the manifest entry
# (the shared manifest stays static for known hosts — no content contention).
# --------------------------------------------------------------------------
echo "Test 3: manifest is append-only (no duplicate on re-run)..."
bash "$TEST_DIR/helpers/repos.sh" --dry-run --skip-rate-limit --project-root "$TEST_DIR" "GRQ-A" 2>/dev/null
MANIFEST_COUNT_AFTER=$(jq '.hosts | length' "$TEST_DIR/docs/hosts/index.json")
if [ "$MANIFEST_COUNT_AFTER" -eq 2 ]; then
    pass_test "re-run did not duplicate the manifest entry (still $MANIFEST_COUNT_AFTER)"
else
    fail_test "manifest count changed on re-run (got: $MANIFEST_COUNT_AFTER)"
fi

# --------------------------------------------------------------------------
# Test 4: Config fields (warning_hours/error_hours) survive a success update.
# --------------------------------------------------------------------------
echo "Test 4: config fields preserved through an update..."
TEST_DIR=$(setup_test_env)
cat > "$TEST_DIR/docs/hosts/FX.json" <<'ENDJSON'
{"name": "FX", "last_commit_ts": 1, "warning_days": 1.5, "error_days": 4, "business_days_only": true}
ENDJSON

bash "$TEST_DIR/helpers/repos.sh" --dry-run --skip-rate-limit --project-root "$TEST_DIR" "FX" 2>/dev/null

PRESERVED=$(jq -r '[.warning_days, .error_days, .business_days_only] | @csv' "$TEST_DIR/docs/hosts/FX.json")
UPDATED_TS=$(jq -r '.last_commit_ts' "$TEST_DIR/docs/hosts/FX.json")
if [ "$PRESERVED" = "1.5,4,true" ] && [ "$UPDATED_TS" -gt 1 ]; then
    pass_test "config preserved and last_commit_ts advanced"
else
    fail_test "config not preserved (fields: $PRESERVED, ts: $UPDATED_TS)"
fi

# --------------------------------------------------------------------------
# Test 5 (dashboard): mergeHostRecords drops nulls/invalid and dedupes by name.
# --------------------------------------------------------------------------
echo "Test 5: mergeHostRecords merges per-host records..."
JS_OUTPUT=$(run_js_test '
    const merged = mergeHostRecords([
        { name: "GRQ-23", last_commit_ts: 100 },
        null,                       // a host file that failed to load
        "not-an-object",           // malformed payload
        { last_commit_ts: 5 },      // missing name -> dropped
        { name: "", last_commit_ts: 5 }, // blank name -> dropped
        { name: "GRQ-23", last_commit_ts: 200 } // later record wins
    ]);
    const byName = Object.fromEntries(merged.map((r) => [r.name, r.last_commit_ts]));
    const ok = merged.length === 1 && byName["GRQ-23"] === 200;
    console.log("TEST_RESULT:merge:" + (ok ? "PASS" : "FAIL") + ":count=" + merged.length + " ts=" + byName["GRQ-23"]);
' 2>&1) || true

if echo "$JS_OUTPUT" | grep -q "TEST_RESULT:merge:PASS:"; then
    pass_test "mergeHostRecords filters invalid records and dedupes by name"
else
    fail_test "mergeHostRecords wrong result ($JS_OUTPUT)"
fi

# --------------------------------------------------------------------------
# Test 6 (dashboard): a non-array input yields an empty list (defensive).
# --------------------------------------------------------------------------
echo "Test 6: mergeHostRecords tolerates non-array input..."
JS_OUTPUT2=$(run_js_test '
    const a = mergeHostRecords(undefined).length === 0;
    const b = mergeHostRecords(null).length === 0;
    const c = mergeHostRecords({}).length === 0;
    console.log("TEST_RESULT:defensive:" + ((a && b && c) ? "PASS" : "FAIL") + ":a=" + a + " b=" + b + " c=" + c);
' 2>&1) || true

if echo "$JS_OUTPUT2" | grep -q "TEST_RESULT:defensive:PASS:"; then
    pass_test "mergeHostRecords returns [] for non-array input"
else
    fail_test "mergeHostRecords did not handle non-array input ($JS_OUTPUT2)"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "========================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
