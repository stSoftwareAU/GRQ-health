## Summary

Documented and implemented the caller integration path for reporting task
failures through `helpers/repos.sh`, so external task runners can adopt the
`--failed --log` contract introduced in #76. Closes #78.

Changes:

- **`helpers/REPO_HEALTH_SNIPPET.md`** — added a "Reporting failures with a
  log file" section with:
  - The exact inline `if/else` copy-paste pattern from the issue.
  - A simpler sourceable-helper alternative (`report_repo_health`).
  - A flag reference table (`--failed`, `--log`, `--exit-code`, `--message`).
  - An explicit security warning that log contents are published publicly on
    GitHub Pages and that callers must redact secrets before handing over a
    log file.
  - A log-retention note (last 5 per task, slugged directory naming).
  - A backwards-compatibility statement for existing success-only callers.
- **`helpers/repo-health-snippet.sh`** — refactored from a standalone
  copy-paste script into a sourceable library that exposes a single
  `report_repo_health <task> <log_file>` function. The function:
  - Captures `$?` on entry and chooses success vs. failure automatically.
  - Calls `repos.sh "<task>"` on success.
  - Calls `repos.sh "<task>" --failed --log "<log>" --exit-code "<N>"` on
    failure.
  - Preserves the original exit code so the caller can propagate it.
  - Honours `GRQ_HEALTH_DIR` / `GRQ_HEALTH_REPO` env overrides.
  - Clones the GRQ-health checkout if missing, and prints a usage message
    when executed directly rather than sourced.
- **`README.md`** — added a cross-link from the "Repo Freshness JSON" /
  "Recording failures" section to the new failure-reporting documentation so
  operators land in the right place.
- Bumped `VERSION` from 1.1.7 → 1.1.8 and synced via `update_version.sh`.

## Evidence

This change is backend/CLI documentation plus a sourceable bash helper — there
is no web UI surface to screenshot. Verification is via the new unit tests
(see Test Plan) and the existing `test-repos-failure.sh` / `test-repos-validation.sh`
which continue to pass.

`./quality.sh` result:

```
Total tests: 28
Passed: 28
Failed: 0
QUALITY CHECK PASSED
```

## Test Plan

- **Added** `tests/test-report-repo-health.sh` with 8 assertions that source
  the refactored `repo-health-snippet.sh` and drive `report_repo_health`
  against a stub `repos.sh`:
  1. `report_repo_health` is defined after sourcing.
  2. Success path (`$? == 0`) invokes `repos.sh` with only the task name.
  3. Failure path (`$? != 0`) invokes `repos.sh` with `--failed --log`.
  4. Failure path also records `--exit-code <N>`.
  5. The function returns the original non-zero exit code on failure (`7`).
  6. The function returns `0` on success.
  7. `GRQ_HEALTH_DIR` override is honoured.
  8. An empty task name is rejected with a non-zero return.
- **Existing tests kept passing**:
  - `tests/test-repos-failure.sh` — failure-mode contract in `repos.sh`.
  - `tests/test-repos-validation.sh` — repo-name validation, including
    command-injection guards.
  - All 28 tests in `./quality.sh` pass cleanly.
- **No regressions for success-only callers**: the default
  `repos.sh "<task>"` invocation is unchanged. The `REPO_HEALTH_SNIPPET.md`
  copy-paste template for the original success-only pattern is retained in
  the same file.
