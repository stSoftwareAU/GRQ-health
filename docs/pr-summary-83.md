## Summary
Updated README.md and docs/README.md disk threshold documentation to match the actual code constants in `docs/dashboard.js` (80% warning / 77% hysteresis clear) instead of the stale 75% / 72% figures. Added a plain-English explanation of the hysteresis band (77–80%). Closes #83.

## Changes
- `README.md`: Updated "Disk usage under 75%" to "under 80%", "at or above 75%" to "at or above 80%", "dropping to or below 72%" to "dropping to or below 77%". Added sentence explaining hysteresis behaviour.
- `docs/README.md`: Updated matching stale thresholds (75% to 80%, "over 75%" to "at or above 80% with hysteresis").
- `tests/test-readme-disk-thresholds.sh`: New test that extracts DISK_WARNING_PERCENT and DISK_WARNING_CLEAR_PERCENT from dashboard.js and verifies README.md documents the correct values.

## Evidence
Documentation-only change — no UI or performance impact. Verified by:
- New test `test-readme-disk-thresholds.sh` (6 assertions) confirms README values match code constants
- All 30 quality checks pass including the new test

## Test Plan
- Added `tests/test-readme-disk-thresholds.sh` with 6 test cases:
  - README healthy threshold matches code (under 80%)
  - README warning trigger matches code (at or above 80%)
  - README clear threshold matches code (dropping to or below 77%)
  - No stale 75% value remains in README
  - Hysteresis behaviour is explained
  - Both 77% and 80% thresholds are referenced
