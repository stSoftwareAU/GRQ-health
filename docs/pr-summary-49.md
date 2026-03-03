## Summary

Add hysteresis to disk usage warning threshold to prevent oscillation when disk usage hovers around the 75% boundary. Closes #49.

**How it works:**
- To **trigger** a disk warning: usage must exceed 75% (`DISK_WARNING_PERCENT`)
- To **clear** a disk warning: usage must drop below 72% (`DISK_CLEAR_PERCENT`)
- In the hysteresis band (72–75%): the previous state is maintained

This prevents noisy status flapping when disk usage fluctuates around the threshold due to temporary files or log rotation.

**Changes:**
- Added `DISK_CLEAR_PERCENT: 72` to `THRESHOLDS` in `dashboard.js`
- Extended `getHealthStatus()` to accept an optional `options.previousDiskWarning` parameter
- Added `getHealthStatusWithHysteresis()` wrapper that tracks per-host disk warning state
- Updated all dashboard callers to use the hysteresis-aware wrapper
- Applied matching hysteresis logic to `simple.html`
- Updated `extract-functions.sh` line ranges for shifted code

## Evidence

This is a backend/logic change with no visual UI differences. The behaviour is verified by 10 unit tests covering:
- Threshold existence and relationship
- Warning trigger above 75%
- Healthy state below 72%
- Hysteresis band behaviour with and without previous warning
- Boundary conditions (exactly at threshold values)
- Backwards compatibility (no options parameter)

## Test Plan

- Added `tests/test-disk-hysteresis.sh` with 10 tests covering the hysteresis band behaviour
- All 18 existing quality checks continue to pass
- Updated `tests/test-xss-prevention.sh` extraction range for shifted line numbers
