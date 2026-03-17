## Summary
Only upload one log file per host — the per-user log (e.g. `node-score.log`) — instead of duplicating it as both `node-score.log` and `node.log`. The dashboard and log viewer now link directly to the per-user log file. Closes #63.

### Changes
- **run.sh**: Removed the backwards-compatibility `node.log` copy. Only `node-${USER_SLUG}.log` is created.
- **dashboard.js**: Added `getHostLogFilename(data)` pure function that returns the per-user log filename for single-user hosts. The "View Log" button now links to `node-<user>.log` instead of `node.log`.
- **log-viewer.html**: Title now shows the actual filename from the URL instead of hardcoding `node.log`.
- **Documentation**: Updated README.md and docs/README.md to reflect the removal of `node.log`.

## Evidence
This is a backend/CLI change with no new visual output. The fix was verified through automated tests.

## Test Plan
- Added `tests/test-single-log-upload.sh` — 5 tests verifying `getHostLogFilename()` returns correct per-user log filenames for single-user, multi-user, no-user, sanitised-slug, and filtered-entry scenarios.
- Added `tests/test-log-copy-single-file.sh` — 3 tests verifying `run.sh` no longer contains the `LOG_DEST_LATEST` variable or copies to a generic `node.log`.
- Updated `tests/test-xss-prevention.sh` line range to account for the new function.
- All 23 quality checks pass.
