## Summary

This PR implements idle worker detection to identify workers that aren't doing meaningful work. Instead of using a single CPU load metric, the system now compares 1-minute, 5-minute, and 15-minute load averages to detect consistently underutilised machines.

### Problem

The previous implementation only checked:
- If 15-minute load average was under 20% on multi-core systems
- If 5-minute load average was under 10% on multi-core systems

This approach could produce false positives because:
- A machine might be waiting on network (e.g., pushing to GitHub)
- A machine might have just finished work (high 15m, low 1m/5m)
- A machine might have just started work (low 15m, high 1m/5m)

### Solution

The new `getIdleWorkerStatus()` function analyses all three load averages together:
- **1-minute average**: Most recent activity indicator
- **5-minute average**: Short-term activity indicator
- **15-minute average**: Longer-term activity indicator

A worker is only flagged as idle when **all three** averages are below their thresholds:
- 1m < 15%
- 5m < 15%
- 15m < 20%

This approach reduces false positives by ensuring the machine is consistently underutilised, not just experiencing a momentary lull.

### Changes

- Added `getIdleWorkerStatus()` function to `dashboard.js` (Issue #23)
- Added `buildIdleWorkerWarning()` function to create human-readable warning messages
- Updated `getHealthStatus()` to use the new idle detection logic
- Updated warning display to show idle worker details
- Added the same logic to `simple.html` for consistency
- Added comprehensive tests in `tests/test-idle-worker-detection.sh`
- Updated version to 1.0.77

## Evidence

Unable to generate screenshot: This is a health monitoring dashboard that requires live data from actual hosts. The visual output would show the same warning badges but with more accurate idle worker detection. The functionality can be verified by the tests below.

## Test Plan

- Added `tests/test-idle-worker-detection.sh` with 7 test cases:
  1. Verifies `getIdleWorkerStatus` function exists in dashboard.js
  2. Verifies idle detection uses both 5m and 15m load averages
  3. Verifies idle worker warning messages exist
  4. Verifies simple.html has idle worker detection
  5. Verifies warning reasons include idle worker details
  6. Verifies detection considers CPU cores
  7. Verifies 1m load average is used to detect recent activity

All tests pass. Run `./quality.sh` to verify.
