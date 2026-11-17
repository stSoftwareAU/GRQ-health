#!/bin/bash
# Test for Issue #155: Holiday-aware staleness.
#
# business_days_only counting (Issue #47/#67) already skips weekends so that
# mid-week silence accrues staleness faster than a weekend gap. A market
# holiday that extends a weekend (e.g. a Monday public holiday) should be
# treated the same way — it must NOT burn into a repo's staleness budget.
#
# These tests exercise the new market-holiday calendar (US NYSE + AU ASX):
#   - isMarketHoliday() recognises US and AU market holidays (and only those)
#   - countBusinessDays() skips holidays as well as weekends
#   - getRepoStatus() keeps a business_days_only repo healthy across a
#     holiday-extended weekend that plain calendar counting would flag.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extract-functions.sh"

echo "Testing Issue #155: Holiday-aware staleness"
echo "==========================================="
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

# ============================================================
# Test 1: isMarketHoliday recognises US and AU market holidays
# ============================================================
echo "Test 1: isMarketHoliday recognises US and AU holidays..."

run_and_check "au-holiday-recognised" '
    // AU: Australia Day (observed) Mon 2026-01-26
    const d = new Date(Date.UTC(2026, 0, 26));
    if (isMarketHoliday(d) === true) {
        console.log("TEST_RESULT:au-holiday-recognised:PASS:2026-01-26 is a holiday");
    } else {
        console.log("TEST_RESULT:au-holiday-recognised:FAIL:expected holiday");
    }
'

run_and_check "us-holiday-recognised" '
    // US: Thanksgiving Thu 2026-11-26
    const d = new Date(Date.UTC(2026, 10, 26));
    if (isMarketHoliday(d) === true) {
        console.log("TEST_RESULT:us-holiday-recognised:PASS:2026-11-26 is a holiday");
    } else {
        console.log("TEST_RESULT:us-holiday-recognised:FAIL:expected holiday");
    }
'

run_and_check "ordinary-day-not-holiday" '
    // An ordinary mid-week trading day.
    const d = new Date(Date.UTC(2026, 2, 4)); // Wed 2026-03-04
    if (isMarketHoliday(d) === false) {
        console.log("TEST_RESULT:ordinary-day-not-holiday:PASS:2026-03-04 is not a holiday");
    } else {
        console.log("TEST_RESULT:ordinary-day-not-holiday:FAIL:expected non-holiday");
    }
'

# ============================================================
# Test 2: countBusinessDays skips holidays as well as weekends
# ============================================================
echo ""
echo "Test 2: countBusinessDays skips holidays..."

# Fri 2026-01-23 -> Tue 2026-01-27. Days after Friday: Sat, Sun (weekend),
# Mon 2026-01-26 (Australia Day holiday), Tue 2026-01-27 (trading).
# Only Tuesday counts => 1 business day (would be 2 without holiday skipping).
run_and_check "count-skips-holiday" '
    const fri = Date.UTC(2026, 0, 23) / 1000;
    const tue = Date.UTC(2026, 0, 27) / 1000;
    const n = countBusinessDays(fri, tue);
    if (n === 1) {
        console.log("TEST_RESULT:count-skips-holiday:PASS:1 business day across holiday-extended weekend");
    } else {
        console.log("TEST_RESULT:count-skips-holiday:FAIL:expected 1, got " + n);
    }
'

# Control: a plain mid-week span with no holiday counts every weekday.
# Mon 2026-03-02 -> Thu 2026-03-05 = Tue, Wed, Thu = 3 business days.
run_and_check "count-plain-midweek" '
    const mon = Date.UTC(2026, 2, 2) / 1000;
    const thu = Date.UTC(2026, 2, 5) / 1000;
    const n = countBusinessDays(mon, thu);
    if (n === 3) {
        console.log("TEST_RESULT:count-plain-midweek:PASS:3 business days mid-week");
    } else {
        console.log("TEST_RESULT:count-plain-midweek:FAIL:expected 3, got " + n);
    }
'

# ============================================================
# Test 3: getRepoStatus stays healthy across a holiday-extended weekend
# ============================================================
echo ""
echo "Test 3: business_days_only repo healthy across holiday-extended weekend..."

# FX-like repo: warning_days 1.5, business_days_only true.
# Last commit Fri 2026-01-23 noon, checked Tue 2026-01-27 morning.
# 1 business day (Mon is Australia Day) < 1.5 => healthy.
run_and_check "holiday-weekend-healthy" '
    const fridayNoon = Date.UTC(2026, 0, 23) / 1000 + 43200;
    const tuesMorn = Date.UTC(2026, 0, 27) / 1000 + 36000;
    const repo = {
        name: "FX",
        last_commit_ts: fridayNoon,
        warning_days: 1.5,
        error_days: 4,
        business_days_only: true
    };
    const status = getRepoStatus(repo, tuesMorn);
    if (status === "healthy") {
        console.log("TEST_RESULT:holiday-weekend-healthy:PASS:healthy across holiday-extended weekend");
    } else {
        console.log("TEST_RESULT:holiday-weekend-healthy:FAIL:expected healthy, got " + status);
    }
'

# Mid-week contrast: same repo, silence Mon 2026-03-02 -> Fri 2026-03-06 (no
# holidays). 4 business days > error_days? No, error 4 => not >. Use warning:
# Tue/Wed/Thu/Fri = 4 business days > warning 1.5 => at least warning. This
# proves mid-week silence of the same wall-clock length is treated as MORE
# suspicious than the holiday-extended weekend above (which stayed healthy).
run_and_check "midweek-more-suspicious" '
    const monNoon = Date.UTC(2026, 2, 2) / 1000 + 43200;
    const friMorn = Date.UTC(2026, 2, 6) / 1000 + 36000;
    const repo = {
        name: "FX",
        last_commit_ts: monNoon,
        warning_days: 1.5,
        error_days: 4,
        business_days_only: true
    };
    const status = getRepoStatus(repo, friMorn);
    if (status !== "healthy") {
        console.log("TEST_RESULT:midweek-more-suspicious:PASS:mid-week silence flagged " + status);
    } else {
        console.log("TEST_RESULT:midweek-more-suspicious:FAIL:expected non-healthy, got healthy");
    }
'

# ============================================================
echo ""
echo "==========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
echo "All Issue #155 holiday-aware tests passed!"
