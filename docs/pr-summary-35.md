## Summary

Extract remaining magic numbers into the `THRESHOLDS` named constants object in `dashboard.js` (Issue #35).

The `THRESHOLDS` object already existed with 8 keys but several hardcoded values remained scattered through the code. This PR:

- Added `USER_STALE_DEFAULT_HOURS: 24` — replaces the hardcoded `24` in `getUserHeartbeatWarningHours()` (the default hours before a user is marked stale)
- Added `IDLE_HIGH_LOAD: 50` — replaces the hardcoded `50` in `getIdleWorkerStatus()` (load above which indicates active work for recently-started/stopped detection)
- Replaced hardcoded `15` and `20` in the "recently stopped/started work" checks with `THRESHOLDS.IDLE_LOAD_1M` and `THRESHOLDS.IDLE_LOAD_15M`
- Updated `extract-functions.sh` line range from 27-659 to 27-661 and `test-xss-prevention.sh` line range from 661-943 to 663-945 to account for the 2 new lines in THRESHOLDS
- Bumped version from 1.0.81 to 1.0.82

## Evidence

This is a backend/logic-only change with no visual impact. All 16 quality gate tests pass, including 13 threshold-specific tests.

## Test Plan

- Extended `tests/test-thresholds-constants.sh` with 5 new tests (Tests 9-13):
  - **new-keys-exist**: Verifies `USER_STALE_DEFAULT_HOURS` and `IDLE_HIGH_LOAD` are present in THRESHOLDS
  - **sensible-values**: Updated to validate all 10 threshold keys (was 8)
  - **user-stale-default**: Verifies `getUserHeartbeatWarningHours({})` returns `THRESHOLDS.USER_STALE_DEFAULT_HOURS`
  - **recently-stopped-work**: Verifies high 15m load with low 1m/5m is not flagged idle (uses IDLE_HIGH_LOAD)
  - **recently-started-work**: Verifies high 1m load with low 15m is not flagged idle (uses IDLE_HIGH_LOAD)
  - **ubuntu-min-version**: Verifies Ubuntu below `THRESHOLDS.UBUNTU_MIN_VERSION` triggers warning
- All existing tests continue to pass unchanged
