## Summary

Created top improvement suggestions as GitHub issues and implemented the three most impactful ones:

1. **XSS prevention** (Issue #34): Added `escapeHtml()` function to `dashboard.js` and applied it to all `innerHTML` interpolations where JSON data is inserted. This prevents cross-site scripting attacks if `index.json` or `repos.json` were compromised.

2. **Named threshold constants** (Issue #35): Extracted magic numbers (disk warning %, heartbeat critical hours, idle detection thresholds, OS version minimums) into a `THRESHOLDS` constant object at the top of `dashboard.js`. This makes thresholds self-documenting and easy to change.

3. **Input validation for repos.sh** (Issue #36): Added `validate_repo_name()` function that rejects repo names containing shell-dangerous characters (spaces, semicolons, pipes, angle brackets, etc.). Added `--validate` flag for testing without side effects.

Additionally created issues for future improvements:
- Issue #37: Keyboard accessibility for dashboard filter controls
- Issue #38: Add quality.sh to CI/CD pipeline

## Evidence

These are backend/CLI changes with no visual impact on the dashboard — the rendered output is identical since escapeHtml is a no-op on clean data. Tests verify the functional behaviour.

## Test Plan

- `tests/test-escape-html.sh` — 8 tests verifying escapeHtml handles angle brackets, ampersands, quotes, null/undefined, numbers, XSS payloads, and safe text
- `tests/test-thresholds-constants.sh` — 8 tests verifying THRESHOLDS object exists with correct keys, and that getHealthStatus/getIdleWorkerStatus use the constants correctly
- `tests/test-repos-validation.sh` — 12 tests verifying repos.sh accepts valid names (alphanumeric, hyphens, underscores, periods) and rejects invalid names (shell metacharacters, spaces, empty strings)
- All 10 existing test suites continue to pass unchanged
