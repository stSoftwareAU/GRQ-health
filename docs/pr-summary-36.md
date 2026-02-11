## Summary
Added comprehensive test coverage for input validation in `helpers/repos.sh` (issue #36). The validation function and `--validate` flag already existed; this change strengthens the test suite with command injection vectors, stderr verification, and edge-case coverage.

## Evidence
This is a purely backend/CLI change with no visual output. Evidence is provided by the test results:

- **27 tests pass** covering valid names, invalid names, command injection attempts, stderr output, and missing arguments
- All tests exercise the real `validate_repo_name` function via the `--validate` flag — no source-code grepping
- `quality.sh` passes cleanly (16/16 checks)

## Test Plan
Enhanced `tests/test-repos-validation.sh` with the following additional test cases:

- **Valid names**: Added `org/repo`, `host:path`, `repo+extra`, `A`, `a1b2c3` to cover all allowed characters
- **Command injection**: Added `$(whoami)`, `` `id` ``, `repo;ls`, `repo$(cat /etc/passwd)`, `` repo`rm -rf /` ``, `{evil}`, `a\nb`
- **Stderr verification**: Confirmed error messages for invalid and empty names go to stderr (not stdout)
- **Missing argument**: Verified `--validate` without a repo name fails correctly
