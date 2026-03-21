## Summary
Add automatic recovery when `index.json` is corrupted or removed. Previously, if the file became invalid JSON (e.g., from a partial write or disk error), `run.sh` would fail to update it and leave it corrupted. Now `run.sh` validates the file before and after writing, recovers from corruption by creating a fresh entry, and preserves a `.bak` backup for safety. The dashboard also shows more helpful error messages distinguishing between missing and corrupted files. Closes #65.

## Changes
- **run.sh**: Pre-write validation detects corrupted JSON and recovers by treating it as missing (preserving the corrupted file as `.corrupted.<timestamp>` for diagnosis)
- **run.sh**: Post-write validation ensures we never leave a corrupted file; restores from `.bak` backup if validation fails
- **run.sh**: Better error handling when `jq` update fails mid-write — restores from backup instead of leaving partial output
- **dashboard.js**: `loadData()` error handler now distinguishes `SyntaxError` (corrupted JSON) from HTTP 404 (missing file) and provides specific recovery guidance
- **Version**: Bumped to 1.0.91

## Evidence
This is a backend/data-integrity fix with no visual UI changes. Evidence is provided by the test results below.

## Test Plan
- Added `tests/test-json-integrity.sh` with 6 test cases:
  1. Missing `index.json` — creates a new valid file
  2. Corrupted `index.json` — detects corruption and recovers to valid JSON
  3. Empty `index.json` — handles empty file gracefully
  4. Valid `index.json` — preserves existing hosts when adding new ones
  5. Post-write validation — confirms output has required fields
  6. Corruption reporting — warns in output when corruption is detected
- All 24 existing tests continue to pass
