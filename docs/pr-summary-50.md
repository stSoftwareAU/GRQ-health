## Summary

Fixed copy-paste bug in idle detection's "recently stopped work" check where `THRESHOLDS.IDLE_LOAD_15M` (20%) was used for the 5-minute load comparison instead of the semantically correct `THRESHOLDS.IDLE_LOAD_5M` (15%). Closes #50.

The fix changes line 224 of `docs/dashboard.js` from:
```js
load5m < THRESHOLDS.IDLE_LOAD_15M
```
to:
```js
load5m < THRESHOLDS.IDLE_LOAD_5M
```

## Evidence

This is a backend logic fix with no visual changes. The fix is verified by automated tests that exercise the `getIdleWorkerStatus()` function with boundary values between the two thresholds (15% and 20%).

## Test Plan

- Added **Test 9** (`recently-stopped-5m-threshold`): Verifies behaviour when `load5m` is 17% (between `IDLE_LOAD_5M` at 15% and `IDLE_LOAD_15M` at 20%), confirming the correct threshold is applied
- Added **Test 10** (`recently-stopped-below-5m`): Verifies the recently-stopped exemption fires correctly when `load5m` is below `IDLE_LOAD_5M`
- All 11 idle detection tests pass
- All 16 quality checks pass
