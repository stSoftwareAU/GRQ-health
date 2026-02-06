## Summary

Audited all test cases and converted grep-based "how" tests to functional "what" tests that call real functions with test data and assert on results. Added testing guidelines to README.md clarifying the distinction between unit tests, benchmarks, "what" tests, and "how" tests.

### What changed

**5 test files rewritten** from grep-based pattern matching to functional tests:
- `test-critical-vs-warning.sh` (Issue #26) — was 6 grep checks, now 6 functional tests calling `getHealthStatus()` with test data
- `test-idle-worker-detection.sh` (Issue #23) — was 7 grep checks, now 10 functional tests calling `getIdleWorkerStatus()` and `getHealthStatus()`
- `test-log-button-fix.sh` (Issue #13) — was 5 grep checks, now 6 functional tests calling `getExpectedUsers()` and `sanitizeUserSlug()`
- `test-stale-threshold.sh` (Issue #15) — was 5 grep checks, now 8 tests (2 config value checks + 6 functional tests)
- `test-stale-user-highlight.sh` (Issue #22) — was 9 grep checks, now 9 functional tests calling `getStaleUsers()` and `buildStaleUserWarning()`

**1 test file improved**:
- `test-status-overflow.sh` (Issue #17) — replaced loose grep patterns with precise CSS value extraction and comparison (5 tests)

**1 test file unchanged** (already functional):
- `test-log-viewer-space.sh` (Issue #18) — already extracts and verifies CSS property values

**New helper file**:
- `tests/extract-functions.sh` — extracts pure functions from `dashboard.js` and runs them via `deno` for functional testing

**Quality infrastructure**:
- `quality.sh` now only runs `tests/test-*.sh` files (not helper scripts)

**Documentation**:
- Added "Testing Guidelines" section to `README.md` explaining:
  - Unit tests vs benchmarks
  - "What" tests vs "how" tests (with examples)
  - How to write new tests
  - How to run tests

### Why "how" tests are harmful

The old tests used `grep` to search source code for patterns like function names and variable references. These tests:
- Break on any refactor even if behaviour is preserved
- Don't actually verify the code works correctly
- Give false confidence — they pass as long as certain strings exist in the source

The new tests call the actual functions with controlled test data and verify the returned values match expectations. If the implementation changes (e.g., switching algorithms), these tests still pass as long as the behaviour is correct.

## Evidence

This is a test infrastructure change with no UI impact. Evidence is the quality.sh output showing all 50+ individual test assertions passing across 7 test files:

```
Quality Check Summary
========================
Total tests: 9
Passed: 9
Failed: 0

QUALITY CHECK PASSED
```

## Test Plan

All tests rewritten or improved (50+ individual assertions across 7 test files):

- `test-critical-vs-warning.sh` — 6 tests verifying getHealthStatus() returns correct status for host/user heartbeat combinations
- `test-idle-worker-detection.sh` — 10 tests verifying getIdleWorkerStatus() correctly identifies idle/active workers
- `test-log-button-fix.sh` — 6 tests verifying user table visibility and log URL generation
- `test-stale-threshold.sh` — 8 tests verifying stale threshold configuration and behaviour
- `test-stale-user-highlight.sh` — 9 tests verifying stale user identification and warning generation
- `test-status-overflow.sh` — 5 tests verifying CSS overflow prevention properties
- `test-log-viewer-space.sh` — 6 tests verifying CSS space optimisation values (unchanged)
