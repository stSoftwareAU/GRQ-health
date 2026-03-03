## Summary

Add weekend grace period to repo commit staleness checks so that repos using default thresholds do not trigger false warnings over a normal weekend. Closes #47.

### Changes

- Added `countWeekendDays(startTs, endTs)` function that counts Saturday and Sunday days between two timestamps
- Modified `getRepoStatus()` to subtract weekend days from elapsed time when using default thresholds
- Added optional `nowTs` parameter to `getRepoStatus()` for testability
- Added `REPO_DEFAULT_WARNING_DAYS` and `REPO_DEFAULT_ERROR_DAYS` to the `THRESHOLDS` object
- Repos with explicitly configured `warning_days`/`error_days` continue to use calendar days (unaffected)
- Updated `extract-functions.sh` pure function range (27-693) and `test-xss-prevention.sh` createHostCard range to account for the new function

## Evidence

This is a backend/logic change with no visual UI changes. All 17 quality checks pass, including the 13 new weekend grace period tests.

## Test Plan

- Added `tests/test-weekend-grace-period.sh` with 13 tests:
  - `countWeekendDays` correctly counts 0, 2, or 4 weekend days for various spans
  - Default repo: Friday commit is healthy on Monday (weekend grace applied)
  - Default repo: Friday commit is healthy on Sunday
  - Default repo: Thursday commit is healthy on Saturday
  - Default repo: Wednesday commit is NOT healthy on Monday (too many weekdays elapsed)
  - Default repo: Monday commit triggers error on Wednesday (pure weekday staleness)
  - Explicit threshold repo: Friday commit uses calendar days (no grace) — triggers error on Monday
  - Explicit `warning_days` only: still uses calendar days
  - `getRepoStatus` works without `nowTs` parameter (backwards compatible)
  - `THRESHOLDS.REPO_DEFAULT_WARNING_DAYS` and `REPO_DEFAULT_ERROR_DAYS` exist
- All existing tests continue to pass (no tests modified or removed)
