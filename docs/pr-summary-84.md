## Summary
Clarify the "High disk usage" warning message so that when a host is flagged due to hysteresis (current usage below 80% but previously above it), the message makes the reason explicit. Closes #84.

Added `buildDiskWarningMessage(diskPercent, wasPreviouslyWarning)` which returns:
- **At or above threshold**: `High disk usage: X% (>= 80%)`
- **In hysteresis band**: `High disk usage: X% (in hysteresis band, will clear at or below 77%)`
- **Not in warning**: empty string

Threshold values are read from `THRESHOLDS.DISK_WARNING_PERCENT` and `THRESHOLDS.DISK_WARNING_CLEAR_PERCENT` — nothing is hardcoded.

## Evidence
This is a backend/dashboard logic change with no visual layout changes. The warning text is generated in JavaScript and rendered in the warning hosts section. Verified via 11 new unit tests covering both message branches, edge cases, and threshold usage.

All 30 quality checks pass (including the 11 new tests in `test-disk-warning-message.sh`).

## Test Plan
- Added `tests/test-disk-warning-message.sh` with 11 tests:
  - `function-exists` — `buildDiskWarningMessage` is defined
  - `above-threshold-msg` — message includes disk% and trigger threshold
  - `above-threshold-gte` — message contains `>=` symbol
  - `hysteresis-msg` — hysteresis band message mentions "hysteresis"
  - `hysteresis-clear-threshold` — hysteresis message includes the clear threshold
  - `at-threshold-msg` — at exactly the threshold uses the above-threshold message
  - `uses-thresholds` — messages reference THRESHOLDS constants, not hardcoded values
  - `prefix-above` — above-threshold message starts with "High disk usage:"
  - `prefix-band` — hysteresis message starts with "High disk usage:"
  - `no-warning-empty` — returns empty string when not in warning state
  - `band-no-prev-warning` — returns empty when in band but not previously warning
- All existing tests continue to pass (`./quality.sh` — 30/30)
