## Summary
Add hysteresis to the disk usage warning threshold to prevent oscillation when disk usage hovers around 75%. Closes #49.

Previously, a disk hovering at 74-76% would flip between warning and healthy on each heartbeat. Now:
- **Warning triggers** at ≥75% (unchanged)
- **Warning clears** only when disk drops to ≤72% (new clear threshold)
- **Hysteresis band** (73-74%): maintains the previous state, preventing oscillation

## Evidence
![Hysteresis behaviour demo](docs/evidence/hysteresis-demo.png)

## Changes
- Added `DISK_WARNING_CLEAR_PERCENT: 72` to `THRESHOLDS` in `dashboard.js`
- Added pure `isDiskWarning(diskPercent, wasPreviouslyWarning)` function
- Modified `getHealthStatus` to accept optional `options.diskWarningActive` parameter
- Added per-host disk warning state tracking via `diskWarningState` map and `refreshHealthStatuses()` cache
- Updated all dashboard rendering callers to use cached health statuses
- Updated `extract-functions.sh` line range for new function boundaries
- Updated `test-xss-prevention.sh` line ranges for shifted `createHostCard`

## Test Plan
- Added `tests/test-disk-hysteresis.sh` with 12 tests covering:
  - `DISK_WARNING_CLEAR_PERCENT` exists and is below `DISK_WARNING_PERCENT`
  - `isDiskWarning` function exists
  - Disk clearly above threshold triggers warning
  - Disk clearly below clear threshold clears warning
  - Disk in hysteresis band stays warning when previously warning
  - Disk in hysteresis band stays healthy when not previously warning
  - Exact boundary values at 75% (triggers) and 72% (clears)
  - `getHealthStatus` integration with hysteresis options
  - Backward compatibility without options parameter
  - No oscillation scenario: 76% → 75% → 74% stays warning
- Updated `test-thresholds-constants.sh` to include `DISK_WARNING_CLEAR_PERCENT`
- All 18 quality checks pass
