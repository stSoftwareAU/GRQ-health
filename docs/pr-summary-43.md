## Summary

Re-enabled repo name validation in `helpers/repos.sh` with an updated regex that accepts spaces in repo names. The previous regex was too restrictive and had been commented out as a workaround. The new regex allows alphanumeric characters, spaces, hyphens, underscores, periods, colons, forward slashes, plus signs, and equals signs — covering all current repo names in `docs/repos.json` (e.g., "Training Data", "S3 Sync", "Company Reports", "Discovery Snapshot") while still rejecting dangerous characters and command injection attempts. Closes #43.

## Evidence

This is a backend/CLI change with no visual output. Validation is verified by the test suite:
- All 51 test cases pass, including 20 repo names from `docs/repos.json`
- Dangerous inputs (command injection, shell metacharacters) are still rejected

## Test Plan

- Updated `tests/test-repos-validation.sh`:
  - Added space-containing names ("Training Data", "S3 Sync", "Company Reports", "Discovery Snapshot", "ScoreClient:luke") to the valid names test
  - Removed `'repo name'` from the invalid names list since spaces are now valid
  - Added **Test 7**: reads every name from `docs/repos.json` and verifies it passes validation
- All existing injection/security tests remain unchanged and still pass
