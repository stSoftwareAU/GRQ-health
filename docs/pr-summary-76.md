## Summary

Extends `helpers/repos.sh` with a failure-reporting mode and log capture, implementing the data-layer foundation for task failure tracking. Closes #76.

### Changes

- **`helpers/repos.sh`**: Added `--failed --log <path>` flags to record task failures with log capture. Added optional `--exit-code` and `--message` flags. Added `--dry-run` and `--project-root` testing flags. Existing success call path is 100% backwards-compatible.
- **`docs/repos.json` schema**: Extended with optional `last_failure_ts`, `last_failure_log`, `last_failure_exit_code`, and `last_failure_message` fields per repo entry.
- **Log retention**: Logs stored under `docs/logs/<task-slug>/` with a cap of 5 files per task. Older files are deleted atomically.
- **Security**: Task names are sanitised into safe directory slugs. Log paths are validated against path traversal (`../`), absolute paths outside temp/project directories, and symlinks to restricted system paths.
- **Version**: Bumped to 1.1.7 across all files.
- **README.md**: Updated "Repo Freshness JSON" section documenting new fields and failure recording usage.

## Evidence

This is a backend/CLI change with no web interface modifications. Evidence is provided by comprehensive test results:

- All 27 quality checks pass (including 17 new failure-reporting tests)
- Existing `test-repos-validation.sh` (57 tests) continues to pass, confirming backward compatibility
- New `test-repos-failure.sh` covers: success unchanged, failure recording, stdin log capture, slug sanitisation, path traversal rejection, symlink rejection, log retention enforcement, optional flags, and missing flag validation

## Test Plan

New test file `tests/test-repos-failure.sh` with 17 test cases:
- Success call records `last_commit_ts` and does not add failure fields
- `--failed --log <file>` writes log, sets `last_failure_ts` + `last_failure_log`, does not touch `last_commit_ts`
- `--failed --log -` reads log from stdin
- Task slug sanitisation handles colons and spaces (e.g., `ScoreClient:luke` → `ScoreClient-luke`)
- Path traversal (`../`) rejected
- Absolute paths outside project/temp rejected
- Non-existent log files rejected
- Symlinks to restricted paths rejected
- Retention: after 6 failures, only 5 log files remain
- `--exit-code` and `--message` recorded correctly
- `--failed` without `--log` rejected
