## Summary

Fixed the issue where the stale threshold was incorrectly set to the same value as the heartbeat threshold (8 hours). This caused false positives when processes run hourly but heartbeats only update every 8 hours - users would be marked as "stale" exactly when their next heartbeat was due.

### Root Cause
The `USER_STALE_HOURS_DEFAULT` in `run.sh` was set to `"${HEARTBEAT_THRESHOLD_HOURS}"`, meaning both values were 8 hours. As explained in issue #15, if Y (stale threshold) equals X (heartbeat threshold), a user completing their hourly process would be marked stale right when they're about to update.

### Solution
Changed the stale threshold to 24 hours (3x the 8-hour heartbeat threshold), providing adequate margin for timing variations:
- `run.sh`: `USER_STALE_HOURS_DEFAULT=24` (was `"${HEARTBEAT_THRESHOLD_HOURS}"`)
- `dashboard.js`: `getUserHeartbeatWarningHours()` default changed from 8 to 24 hours

### Files Changed
- `run.sh` - Updated default stale threshold and added documentation
- `docs/dashboard.js` - Updated default stale threshold in `getUserHeartbeatWarningHours()`
- `README.md` - Added documentation about heartbeat vs stale threshold relationship
- `quality.sh` - New script to run all tests
- `tests/test-stale-threshold.sh` - New test for stale threshold separation
- `tests/stale-threshold.test.html` - New HTML-based tests for dashboard logic

## Evidence

Unable to generate screenshot: This is a CLI-based health monitoring tool. The changes affect the timing logic for marking users as "stale" in the dashboard, not the visual appearance. The fix can be verified by running the test suite.

### Test Verification
```
$ ./quality.sh
...
Test 1: Checking that USER_STALE_HOURS_DEFAULT is separate from HEARTBEAT_THRESHOLD_HOURS...
  PASS: USER_STALE_HOURS_DEFAULT is set independently of HEARTBEAT_THRESHOLD_HOURS
Test 2: Checking that USER_STALE_HOURS_DEFAULT is at least 24 hours...
  PASS: USER_STALE_HOURS_DEFAULT is 24 hours (>= 24h)
Test 3: Checking that stale threshold is at least 3x heartbeat threshold...
  PASS: Stale threshold (24 h) >= 3x heartbeat (8 h = min 24 h)
Test 4: Checking that dashboard.js default stale threshold is at least 24 hours...
  PASS: Dashboard default stale threshold is 24 hours (>= 24h)
...
QUALITY CHECK PASSED
```

## Test Plan

- Added `tests/test-stale-threshold.sh` - Shell script that verifies:
  1. `USER_STALE_HOURS_DEFAULT` is set independently of `HEARTBEAT_THRESHOLD_HOURS`
  2. `USER_STALE_HOURS_DEFAULT` is at least 24 hours
  3. Stale threshold is at least 3x the heartbeat threshold
  4. Dashboard.js default stale threshold is at least 24 hours
  5. Documentation exists for the threshold relationship

- Added `tests/stale-threshold.test.html` - Browser-based tests that verify:
  1. Default stale threshold is at least 24 hours (3x the 8-hour heartbeat)
  2. Users updated 10/16 hours ago are NOT marked as stale
  3. Users updated 25 hours ago ARE marked as stale
  4. Custom stale thresholds are respected
  5. Regression test ensuring stale != heartbeat threshold
  6. GRQ-3/sloth scenario from issue #15 is handled correctly

- All existing tests continue to pass (`test-log-button-fix.sh`)
