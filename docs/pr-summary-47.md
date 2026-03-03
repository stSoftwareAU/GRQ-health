## Summary

Add weekend grace period to repo commit staleness checks so that repos using default thresholds do not trigger false alarms over a normal weekend. Closes #47.

### What changed

- **New `countBusinessDays(fromTs, toTs)` function** in `dashboard.js` that counts only weekdays (Mon-Fri) between two timestamps, skipping Saturday and Sunday.
- **Updated `getRepoStatus(repo, nowTs)`** to use business days for repos with default thresholds (no explicit `warning_days`/`error_days`). Repos with explicitly configured thresholds continue to use calendar days, completely unaffected.
- **Added optional `nowTs` parameter** to `getRepoStatus` for testability.
- **Updated `extract-functions.sh`** line range to include the new `countBusinessDays` function.
- **Fixed `test-xss-prevention.sh`** line references shifted by the new code.
- **Updated README.md** to document the weekend grace behaviour.
- **Version bumped** to 1.0.86.

### Behaviour summary

| Repo type | Staleness counting | Default thresholds |
|---|---|---|
| No explicit thresholds | Business days (weekdays only) | 1 bday warning, 2 bdays error |
| Explicit `warning_days`/`error_days` | Calendar days (unchanged) | As configured |

## Evidence

![Weekend grace period test results](docs/evidence/weekend-grace-test.png)

The screenshot shows:
- **Default repos**: Friday commit is HEALTHY on Monday (1 business day), Thursday commit is WARNING (2 business days), Wednesday commit is ERROR (3 business days)
- **Explicit repos**: Calendar days still apply — Friday to Monday = 3 calendar days, correctly exceeding a 2-day error threshold

## Test Plan

- Added `tests/test-weekend-grace.sh` with 14 tests covering:
  - `countBusinessDays` function: Mon-Wed, Fri-Mon, full week, Sat-Mon, same timestamp, two-week span
  - Default threshold repos: Friday/Thursday/Wednesday commits checked on Monday
  - Explicit threshold repos: calendar day behaviour preserved
  - Edge cases: no timestamp, same-day commit, partial explicit thresholds
- All 17 existing quality checks continue to pass
