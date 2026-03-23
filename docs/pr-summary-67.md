## Summary

Added `business_days_only` flag for weekend-aware health checks on repos with explicit thresholds. This prevents false alarms for feeds like FX that only run Monday–Friday (NY time). Previously, repos with explicit `warning_days`/`error_days` always used calendar days, causing weekend gaps to trigger warnings on Monday mornings. With `"business_days_only": true`, weekends are skipped when counting staleness. Closes #67.

## Changes

- **`docs/dashboard.js`**: Modified `getRepoStatus()` to check for `business_days_only: true` flag. When set, repos with explicit thresholds use `countBusinessDays()` (skipping weekends) instead of calendar hours.
- **`docs/repos.json`**: Added `"business_days_only": true` to the FX repo entry.
- **`tests/test-weekend-aware-repos.sh`**: Added 8 new tests covering the FX weekend scenario, threshold behaviour, backward compatibility, partial thresholds, and edge cases.
- **`tests/extract-functions.sh`**: Updated pure function extraction range (29-736) to account for the 2 added lines.
- **`tests/test-xss-prevention.sh`**: Updated `createHostCard` extraction range (738-1048) to match the shifted line numbers.
- **`README.md`**: Documented the new `business_days_only` flag with usage example.
- **Version**: Bumped from 1.0.91 to 1.0.92.

## Evidence

This is a backend logic change with no visual UI modifications. The fix is verified by 8 new unit tests (all passing) plus all 25 existing quality checks passing.

Key test scenario: FX repo updated Friday noon, checked Monday morning — without `business_days_only` returns "warning" (3 calendar days > 1.5 threshold), with `business_days_only: true` returns "healthy" (1 business day < 1.5 threshold).

## Test Plan

- `tests/test-weekend-aware-repos.sh` — 8 new tests:
  - FX-like repo stays healthy over weekend (Friday→Monday)
  - Warns after enough business days (Friday→Wednesday)
  - Errors after error threshold in business days
  - Backward compatibility: no flag still uses calendar days
  - Partial explicit thresholds with business_days_only
  - `business_days_only: false` treated same as not set
  - Same-day check is healthy
  - Saturday check after Friday update is healthy
- All 14 existing weekend grace tests (`test-weekend-grace.sh`) continue to pass
- All 25 quality checks pass
