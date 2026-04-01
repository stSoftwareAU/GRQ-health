## Summary
Increased the high disk alarm threshold from 75% to 80% as requested. The hysteresis clear threshold was also updated from 72% to 77%, maintaining the 3-point gap to prevent oscillation. Closes #71.

## Changes
- `docs/dashboard.js`: Updated `DISK_WARNING_PERCENT` from 75 to 80 and `DISK_WARNING_CLEAR_PERCENT` from 72 to 77
- `tests/test-thresholds-constants.sh`: Added tests 13-14 to verify the new threshold values (80% warning, 77% clear)
- `tests/test-disk-hysteresis.sh`: Updated test 12 to use threshold-relative values instead of hardcoded numbers, making it resilient to future threshold changes

## Evidence
This is a backend threshold change with no UI layout changes. All 26 quality checks pass, including the disk hysteresis and threshold constant test suites.

## Test Plan
- Added test asserting `DISK_WARNING_PERCENT === 80` (test 13 in test-thresholds-constants.sh)
- Added test asserting `DISK_WARNING_CLEAR_PERCENT === 77` (test 14 in test-thresholds-constants.sh)
- Refactored hysteresis oscillation test to use `THRESHOLDS` constants instead of hardcoded values
- All existing tests continue to pass with the updated thresholds
