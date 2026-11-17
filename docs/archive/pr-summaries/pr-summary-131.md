## Summary

Raised the disk-usage warning threshold in the dashboard from 80% to 90%, and moved the hysteresis clear threshold from 77% to 87% to preserve the existing 3-percentage-point gap. Closes #131.

- `docs/dashboard.js`: `DISK_WARNING_PERCENT` 80 → 90, `DISK_WARNING_CLEAR_PERCENT` 77 → 87.
- `README.md` and `docs/README.md`: health-status documentation updated to the new thresholds.
- Tests updated so threshold-constant assertions and hard-coded sample values reflect the new boundaries; threshold-relative tests are unchanged.

## Evidence

Backend/CLI change with no UI layout difference — the dashboard simply flags fewer hosts because the trigger moved up by 10 points. Tested via the existing test suite:

- `tests/test-thresholds-constants.sh` — asserts `DISK_WARNING_PERCENT === 90` and `DISK_WARNING_CLEAR_PERCENT === 87`.
- `tests/test-disk-hysteresis.sh` — verifies `isDiskWarning` triggers above 90% and clears at/below 87% (threshold-relative cases unchanged; one hard-coded sample bumped to 95%).
- `tests/test-disk-warning-message.sh` — verifies above-threshold and in-band branches of `buildDiskWarningMessage` with the new thresholds.
- `tests/test-readme-disk-thresholds.sh` — extracts the constants from `dashboard.js` and confirms the README documents the same values.

`./quality.sh` passes apart from a pre-existing, unrelated `test-gitleaks-workflow.sh` failure (`Missing gitleaks-action step or GITHUB_TOKEN env`) that also fails on `origin/Develop`.

## Test Plan

- [x] `./quality.sh < /dev/null` — 48 of 49 tests pass; the one failure is pre-existing on Develop and unrelated to disk thresholds.
- [x] `tests/test-thresholds-constants.sh` updated to assert the new 90 / 87 values.
- [x] `tests/test-disk-warning-message.sh` updated so the hard-coded above-threshold samples (85 → 95, 85.2 → 95.2) still exercise the above-threshold branch under the new 90% trigger.
- [x] `tests/test-disk-hysteresis.sh` hard-coded "above threshold" sample bumped from 80 to 95.
- [x] `tests/test-readme-disk-thresholds.sh` continues to pass because the README was updated to match the new constants.
