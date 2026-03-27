## Summary

Per-user status badge in the multi-user table only checked heartbeat staleness — a user like "elephant" with `exception_count > 0` but a recent heartbeat was incorrectly shown as "ok". Added a `getUserStatus()` function that checks both staleness AND exception count, and also added per-user exception detection in `getHealthStatus()` so the host is flagged as warning even if only a user-level exception exists. Closes #69.

## Evidence

![Before/After comparison of per-user exception status badge](docs/evidence/issue-69-fix.png)

**Before**: elephant showed a green "ok" badge despite having 1 error.
**After**: elephant shows a yellow "errors" badge. Priority order: stale > errors > ok.

## Test Plan

- Added `tests/test-user-exception-status.sh` with 10 test cases:
  - User with exceptions and recent heartbeat shows "errors"
  - User with no exceptions and recent heartbeat shows "ok"
  - Stale user takes priority over exceptions (shows "stale")
  - Missing heartbeat shows "stale"
  - String exception_count handled correctly
  - Zero exception_count (string and number) shows "ok"
  - Missing exception_count field shows "ok"
  - Host-level getHealthStatus returns "warning" when user has exceptions
  - Per-user exceptions detected even without host-level exception_count
  - Host without any exceptions returns "healthy"
