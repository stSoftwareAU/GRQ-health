## Summary
Exclude `[MemoryMonitor]` lines when scanning `node.log` for WARNING/ERROR. These lines are operational noise from cache clearing and should not be flagged as errors. Closes #61.

### Changes
- **`run.sh` `scan_log_errors()`**: Filter out `[MemoryMonitor]` lines before scanning for errors by creating a filtered copy of the log file
- **`docs/log-viewer.html`**: Skip `[MemoryMonitor]` lines from warning/error classification in the log viewer display
- **`README.md`**: Document the MemoryMonitor exclusion in the exception detection section

## Evidence
This is a backend/CLI change with no visual UI changes. The fix was verified through automated tests covering both `run.sh` scanning and log-viewer classification.

Test output confirms:
- MemoryMonitor-only logs produce zero errors
- MemoryMonitor lines with ⚠️ and ❌ emojis are excluded
- Real errors mixed with MemoryMonitor lines are still detected correctly
- Log-viewer classifies MemoryMonitor lines as normal (not warning/error)

## Test Plan
- Added `tests/test-memory-monitor-exclusion.sh` with 10 test cases:
  - **run.sh tests (5)**: MemoryMonitor warning lines excluded, emoji lines excluded, real errors still detected alongside MemoryMonitor lines, failure emoji excluded, actual GRQ-18 log content excluded
  - **log-viewer.html tests (5)**: MemoryMonitor WARNING/CRITICAL/Warning-response classified as normal, real WARNING and ERROR still flagged correctly
