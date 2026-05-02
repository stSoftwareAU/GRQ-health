## Summary

Fixed every shellcheck warning the CI ShellCheck workflow flagged
(`severity: warning`). The screenshot in the issue listed 19 warnings across
`run.sh` and seven test scripts — all are now resolved, and a new regression
test (`tests/test-shellcheck-clean.sh`) keeps the warning baseline clean for
future PRs. Closes #114.

## Evidence

`shellcheck --severity=warning` (matching `.github/workflows/shellcheck.yml`)
now reports zero issues across the 49 shell scripts in the repo:

```
$ ./tests/test-shellcheck-clean.sh
Testing Issue #114: shellcheck warning-severity is clean
========================================================

Linting 49 shell scripts at severity=warning...
  PASS: all shell scripts are clean at warning severity

Results: 1 passed, 0 failed
```

Categories fixed:

| Code | Meaning | Files affected |
| ---- | ------- | -------------- |
| SC2155 | Declare and assign separately to avoid masking return values | `run.sh` (7 occurrences in `scan_log_errors` + `update_json`) |
| SC2034 | Variable appears unused | `tests/test-log-viewer-classification.sh`, `tests/test-memory-monitor-exclusion.sh`, `tests/test-push-retry.sh`, `tests/test-repos-push-rebase.sh`, `tests/test-scan-log-errors.sh`, `tests/test-status-overflow.sh` |
| SC2154 | Variable referenced but not assigned (set inside the eval'd run.sh function) | `tests/test-memory-monitor-exclusion.sh`, `tests/test-scan-log-errors.sh` |
| SC2188 | Redirection without a command | `tests/test-json-integrity.sh` (changed `> file` to `true > file`) |

For SC2034/SC2154 inside tests that `eval` functions out of `run.sh`, the
variables are genuinely consumed by the eval'd function — narrow
`# shellcheck disable=...` directives document this.

## Test Plan

- New regression test: `tests/test-shellcheck-clean.sh` runs
  `shellcheck --severity=warning` over every `*.sh` file in the repo and
  fails if any warning surfaces. This is the same severity the GitHub
  Actions workflow uses, so the local gate matches CI.
- All seven modified test files were re-executed individually after the
  changes — every one still passes (`tests/test-json-integrity.sh`,
  `tests/test-log-viewer-classification.sh`,
  `tests/test-memory-monitor-exclusion.sh`, `tests/test-push-retry.sh`,
  `tests/test-repos-push-rebase.sh`, `tests/test-scan-log-errors.sh`,
  `tests/test-status-overflow.sh`).
- `./quality.sh` total tests went from 42 → 43 (added shellcheck regression
  test). The two remaining failures (`test-gitleaks-workflow`,
  `test-vibe-coder-dead-after-8h`) were failing on `Develop` before this
  branch and are unrelated to shellcheck — out of scope for this issue.

## Notes

- Version bumped from `1.1.12` → `1.1.13` per project convention for code
  changes; `./update_version.sh` was run to sync the version across HTML/JS.
- The behaviour of `scan_log_errors` is unchanged: where `grep ... | wc -l`
  was rewritten to `grep -c ...` the count is identical, and the
  declare-and-assign split preserves the existing fallbacks
  (`|| echo "0"`).
