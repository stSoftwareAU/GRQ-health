## Summary
Clarify the "High disk usage" warning message so it distinguishes between above-threshold and hysteresis-band cases. When disk usage is >= 80%, the message reads `High disk usage: X% (>= 80%)`. When in the hysteresis band (77–80%), it reads `High disk usage: X% (in hysteresis band, will clear at or below 77%)`. Threshold values are read from `THRESHOLDS` constants, not hardcoded. Closes #84.

## Changes
- Added `buildDiskWarningMessage(diskPercent)` pure function in `docs/dashboard.js` (after `isDiskWarning`)
- Updated the warning section renderer to call `buildDiskWarningMessage` instead of inline string
- Bumped VERSION to 1.1.10 and ran `update_version.sh`

## Evidence
This is a backend/JS logic change with no new UI layout. The message text is verified by unit tests:
- `High disk usage: 85.2% (>= 80%)` — above threshold
- `High disk usage: 78.4% (in hysteresis band, will clear at or below 77%)` — in band

All 30 quality checks pass including 8 new tests.

## Test Plan
- Added `tests/test-disk-warning-message.sh` with 8 tests covering:
  - `function-exists` — `buildDiskWarningMessage` is defined
  - `above-threshold-msg` — above-threshold message includes usage and trigger threshold
  - `at-threshold-msg` — at exactly the threshold uses `>=` notation
  - `hysteresis-band-msg` — hysteresis message explains hysteresis and includes clear threshold
  - `hysteresis-shows-usage` — hysteresis message includes actual usage percentage
  - `above-no-hysteresis` — above-threshold message does not mention hysteresis
  - `dynamic-thresholds` — threshold values come from `THRESHOLDS` constants
  - `prefix-consistent` — both message variants share consistent prefix
- All existing tests continue to pass (`./quality.sh` — 30/30)
