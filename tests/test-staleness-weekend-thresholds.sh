#!/bin/bash
# Test for Issue #154: Raise Company Reports & Shareprices staleness thresholds
# so a benign "no changes to commit" weekend (GRQ-marketdata#89) does not flag a
# false warning every Monday morning.
#
# Requested config for both tasks (calendar counting, NOT business_days_only):
#   warning_days: 1.5 -> 3
#   error_days:   (unset, default 2) -> 4
#
# Behaviour: with calendar thresholds warning_days=3 / error_days=4, a task whose
# last commit was Friday and is checked the following Monday (3 calendar days) is
# still healthy; the previous 1.5-day warning threshold would have flagged it.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #154: weekend-clearing staleness thresholds"
echo "========================================================="
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

run_and_check() {
    local test_name="$1"
    local js_code="$2"
    local output
    output=$(run_js_test "$js_code" 2>&1) || true
    local result
    result=$(echo "$output" | grep "^TEST_RESULT:${test_name}:" | head -1)
    if [[ "$result" == *":PASS:"* ]]; then
        local detail
        detail=$(echo "$result" | cut -d: -f4-)
        pass_test "$test_name: $detail"
    else
        local detail
        detail=$(echo "$result" | cut -d: -f4-)
        if [ -z "$detail" ]; then
            detail="no output (full: $output)"
        fi
        fail_test "$test_name: $detail"
    fi
}

# Timestamps (midnight UTC):
# Fri 2026-03-06 = 1772755200
# Mon 2026-03-09 = 1773014400
# Tue 2026-03-10 = 1773100800

# ============================================================
# Test 1: getRepoStatus — Friday commit is healthy on Monday
# with the new calendar thresholds (warning 3 / error 4)
# ============================================================
echo "Test 1: Friday commit stays healthy on Monday (3 calendar days)..."

run_and_check "weekend-healthy-monday" '
    const fridayNoon = 1772755200 + 43200; // Fri 2026-03-06 12:00 UTC
    const mondayNoon = 1773014400 + 43200; // Mon 2026-03-09 12:00 UTC (3 calendar days)
    const repo = { name: "Company Reports", last_commit_ts: fridayNoon,
                   warning_days: 3, error_days: 4 };
    const status = getRepoStatus(repo, mondayNoon);
    if (status === "healthy") {
        console.log("TEST_RESULT:weekend-healthy-monday:PASS:3 calendar days is healthy");
    } else {
        console.log("TEST_RESULT:weekend-healthy-monday:FAIL:expected healthy, got " + status);
    }
'

# Regression guard: the OLD config (warning_days=1.5, default error_days=2)
# WOULD have flagged a non-healthy state on Monday — that is the bug we fix.
run_and_check "old-threshold-would-flag" '
    const fridayNoon = 1772755200 + 43200;
    const mondayNoon = 1773014400 + 43200;
    const repo = { name: "Company Reports", last_commit_ts: fridayNoon, warning_days: 1.5 };
    const status = getRepoStatus(repo, mondayNoon);
    if (status !== "healthy") {
        console.log("TEST_RESULT:old-threshold-would-flag:PASS:old 1.5-day config flagged " + status + " (the bug)");
    } else {
        console.log("TEST_RESULT:old-threshold-would-flag:FAIL:expected non-healthy, got " + status);
    }
'

# ============================================================
# Test 2: calendar counting is used (NOT business_days_only)
# ============================================================
echo ""
echo "Test 2: thresholds use calendar days, not business days..."

# 3.5 calendar days > warning(3) but <= error(4) => warning.
run_and_check "calendar-warning-3p5-days" '
    const start = 1772755200;              // Fri 2026-03-06 00:00 UTC
    const later = start + Math.round(3.5 * 86400); // +3.5 calendar days
    const repo = { name: "Shareprices", last_commit_ts: start, warning_days: 3, error_days: 4 };
    const status = getRepoStatus(repo, later);
    if (status === "warning") {
        console.log("TEST_RESULT:calendar-warning-3p5-days:PASS:3.5 calendar days = warning");
    } else {
        console.log("TEST_RESULT:calendar-warning-3p5-days:FAIL:expected warning, got " + status);
    }
'

# 4.5 calendar days > error(4) => error.
run_and_check "calendar-error-4p5-days" '
    const start = 1772755200;
    const later = start + Math.round(4.5 * 86400);
    const repo = { name: "Shareprices", last_commit_ts: start, warning_days: 3, error_days: 4 };
    const status = getRepoStatus(repo, later);
    if (status === "error") {
        console.log("TEST_RESULT:calendar-error-4p5-days:PASS:4.5 calendar days = error");
    } else {
        console.log("TEST_RESULT:calendar-error-4p5-days:FAIL:expected error, got " + status);
    }
'

# ============================================================
# Test 3: configured JSON files carry the requested thresholds
# ============================================================
echo ""
echo "Test 3: JSON config files carry warning_days=3 / error_days=4, no business_days_only..."

REPOS_JSON="$SCRIPT_DIR/../docs/repos.json"
HOSTS_DIR="$SCRIPT_DIR/../docs/hosts"

check_config() {
    # $1 = jq selector expression, $2 = human label
    local selector="$1" label="$2" file="$3"
    local wd ed bdo
    wd=$(jq -r "$selector | .warning_days" "$file")
    ed=$(jq -r "$selector | .error_days" "$file")
    bdo=$(jq -r "$selector | (.business_days_only // false)" "$file")
    if [ "$wd" = "3" ] && [ "$ed" = "4" ] && [ "$bdo" = "false" ]; then
        pass_test "$label: warning_days=3, error_days=4, calendar counting"
    else
        fail_test "$label: warning_days=$wd, error_days=$ed, business_days_only=$bdo"
    fi
}

if command -v jq &> /dev/null; then
    check_config '.repos[] | select(.name=="Company Reports")' "repos.json Company Reports" "$REPOS_JSON"
    check_config '.repos[] | select(.name=="Shareprices")'      "repos.json Shareprices"      "$REPOS_JSON"
    check_config '.' "hosts/Company-Reports.json" "$HOSTS_DIR/Company-Reports.json"
    check_config '.' "hosts/Shareprices.json"      "$HOSTS_DIR/Shareprices.json"
else
    echo "  SKIP: jq not available"
fi

# ============================================================
echo ""
echo "========================================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
echo "All Issue #154 threshold tests passed!"
