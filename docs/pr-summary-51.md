## Summary

Add retry logic to `commit_and_push()` in `run.sh` so that a transient `git push` failure no longer causes a false critical alert lasting up to 8 hours. The push is now retried up to 3 times with a `git pull --rebase` between attempts, handling git conflicts and network blips gracefully. Closes #51.

## Changes

- **`run.sh`**: Replaced the single `git push` attempt with a retry loop (3 attempts). On failure, it pulls with rebase before retrying, logging each attempt.
- **`tests/test-push-retry.sh`**: New test file with 3 test scenarios using a mock `git` binary:
  1. Push succeeds on first try — no retry needed
  2. Push fails once then succeeds on retry — verifies retry behaviour
  3. Push fails all retries — verifies all attempts are made and failure is logged

## Evidence

This is a backend/CLI change with no web interface impact. The retry logic is verified by the test suite which uses mock git binaries to simulate push failures and confirm retry behaviour.

## Test Plan

- Added `tests/test-push-retry.sh` with 5 assertions across 3 scenarios
- All 19 quality checks pass including the new test
