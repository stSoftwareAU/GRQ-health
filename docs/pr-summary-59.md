## Summary

Fixed false positive error detection in `scan_log_errors()` where `.cache/` file-not-found errors were incorrectly counted as "missing commands". These occur normally when emergency disk cleanup removes the `.cache/` directory before `cleanup_cache.sh` runs — a standard concurrency situation, not a configuration error. This false positive was forcing unnecessary log pushes. Closes #59.

## Changes

- `run.sh`: Added `grep -v '\.cache/'` filter to `missing_command_errors` detection to exclude cache file paths from "No such file or directory" checks
- `tests/test-scan-log-errors.sh`: New test file with 6 test cases covering false positive exclusion and real error detection

## Evidence

The fix was verified against the actual `docs/GRQ-24/node-sloth.log` file from the issue. Before the fix, it reported `1 errors found (1 missing commands)`. After the fix, it correctly reports zero errors.

No UI changes were made — this is a backend log scanning fix.

## Test Plan

- Test 1: Cache file not found after cleanup is NOT flagged as an error
- Test 2: Git push rejection (concurrency) is NOT flagged as an error
- Test 3: Real stack trace errors ARE still detected
- Test 4: Real missing script errors ARE still detected
- Test 5: Clean log has zero errors
- Test 6: The actual GRQ-24 node-sloth.log from the issue has no false positives
- All 20 quality checks pass
