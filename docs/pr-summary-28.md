## Summary

Audited all 7 test files and replaced 5 "how" tests (grep-based source code inspection) with proper "what" tests that call real functions with test data and assert on results. Added testing best practices documentation to README.md clarifying the distinction between unit tests, benchmarks, "what" tests, and "how" tests.

### What changed

**Tests rewritten from "how" to "what":**
- `test-critical-vs-warning.sh` — Was grepping for variable names like `hostHeartbeat` and `anyUserStale`. Now calls `getHealthStatus()` with various host/user heartbeat combinations and asserts on the returned status string.
- `test-idle-worker-detection.sh` — Was grepping for function names and keywords. Now calls `getIdleWorkerStatus()` and `buildIdleWorkerWarning()` with test data covering idle, busy, recently-started, recently-finished, and small-system scenarios.
- `test-log-button-fix.sh` — Was grepping for template strings in source code. Now calls `getExpectedUsers()`, `getUserEntries()`, and `sanitizeUserSlug()` to verify the logic that drives button visibility.
- `test-stale-threshold.sh` — Tests 1-2 (config value extraction) were already "what" tests and kept. Tests 3-5 were grep-based and replaced with calls to `getUserHeartbeatWarningHours()` verifying default, override, and invalid-override behaviour.
- `test-stale-user-highlight.sh` — Was grepping for function names and keywords. Now calls `getStaleUsers()` and `buildStaleUserWarning()` with test data covering single-user skip, multi-user stale detection, plural grammar, and "never seen" handling.

**Tests kept as-is:**
- `test-log-viewer-space.sh` — CSS property extraction test (valid per project conventions).
- `test-status-overflow.sh` — CSS property extraction test (valid per project conventions).

**Infrastructure added:**
- `tests/extract-functions.sh` — Helper that extracts pure functions (lines 27-644) from `dashboard.js` and runs JS test code via deno.
- `quality.sh` updated to only run `tests/test-*.sh` files (not helper scripts).

**Documentation:**
- Added "Testing" section to README.md explaining unit tests vs benchmarks, "what" vs "how" tests, how to write JS tests, test file conventions, and what not to do.

## Evidence

This is a test infrastructure and documentation change with no UI modifications. All 9 quality checks pass:

```
Total tests: 9
Passed: 9
Failed: 0
QUALITY CHECK PASSED
```

## Test Plan

- 35 individual test assertions across 5 rewritten test files, all passing
- `test-critical-vs-warning.sh`: 6 tests covering warning/critical/healthy/dead/mia/single-user scenarios
- `test-idle-worker-detection.sh`: 9 tests covering idle/busy/finished/started/small-system/missing-data/warning-text
- `test-log-button-fix.sh`: 6 tests covering single-user/multi-user/no-users/invalid-entries/slug-sanitise/sorting
- `test-stale-threshold.sh`: 5 tests covering config separation, 3x ratio, default/override/invalid-override
- `test-stale-user-highlight.sh`: 8 tests covering stale detection, skip logic, plural grammar, never-seen handling
- 2 CSS tests unchanged (11 assertions total)
- `./quality.sh` passes cleanly
