## Summary
Fixed copy-paste bug in idle detection where the "recently stopped work" exemption used `THRESHOLDS.IDLE_LOAD_15M` (20%) instead of `THRESHOLDS.IDLE_LOAD_5M` (15%) for the 5-minute load comparison. Closes #50.

## Changes
- `docs/dashboard.js` line 224: Changed `THRESHOLDS.IDLE_LOAD_15M` to `THRESHOLDS.IDLE_LOAD_5M` in the recently-stopped work check
- `tests/test-idle-worker-detection.sh`: Added two boundary tests for the recently-stopped exemption threshold

## Evidence
![Test report showing fix](docs/evidence/issue-50-fix.png)

All 11 idle detection tests pass, including:
- **recently-stopped-below-5m**: 5m load at 14% (below IDLE_LOAD_5M=15%) correctly gets the exemption
- **recently-stopped-above-5m**: 5m load at 17% (above IDLE_LOAD_5M=15%) correctly does not get the exemption

## Test Plan
- Added Test 9: `recently-stopped-below-5m` — verifies exemption applies when 5m load is below IDLE_LOAD_5M threshold
- Added Test 10: `recently-stopped-above-5m` — verifies exemption does not apply when 5m load exceeds IDLE_LOAD_5M threshold
- All 16 quality checks pass cleanly
