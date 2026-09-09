## Summary

The five `test`-category CI gates — dependency review, gitleaks, markdown lint,
semgrep and shellcheck — gated `pull_request` on `branches: ["*"]`. GitHub
Actions filter globs treat `*` as matching zero or more characters *excluding*
`/`, so a PR targeting a nested branch such as `milestone/<slug>` matched
nothing and none of the five gates ran on it. Milestone PRs merged unchecked
until the rollup PR into the default branch surfaced the problems much later.

The `branches:` filter is dropped from all five workflows. A bare
`pull_request:` trigger runs on every PR target at any nesting depth, which
fixes the reported gap without introducing a second glob that would break again
on a deeper path (`milestone/a/b`). Each file keeps a short comment recording
why the filter is deliberately absent.

Closes #192.

## Evidence

This is a CI-configuration change with no web interface to screenshot. The
evidence is the new behaviour test, which models GitHub's own filter-pattern
semantics rather than grepping the YAML for a particular spelling of the fix.

Trigger evaluation for a PR targeting `milestone/<slug>`:

```mermaid
flowchart LR
    PR["PR → milestone/192-slug"] --> F{"branches filter?"}
    F -->|"before: [\"*\"]"| X["no match — * excludes /<br/>gate skipped"]
    F -->|"after: no filter"| R["runs on every PR target<br/>gate enforced"]
```

Before the fix (`./tests/test-pr-workflow-branch-filters.sh`, exit 1):

```text
  FAIL: dependency-review.yml skips a PR targeting 'milestone/192-example-slug'; its branch filter excludes it
  FAIL: gitleaks.yml skips a PR targeting 'milestone/192-example-slug'; its branch filter excludes it
  FAIL: markdown-lint.yml skips a PR targeting 'milestone/192-example-slug'; its branch filter excludes it
  FAIL: semgrep.yml skips a PR targeting 'milestone/192-example-slug'; its branch filter excludes it
  FAIL: shellcheck.yml skips a PR targeting 'milestone/192-example-slug'; its branch filter excludes it

Results: 10 passed, 5 failed (5 pull_request workflows checked)
```

After the fix (exit 0):

```text
Results: 15 passed, 0 failed (5 pull_request workflows checked)
```

`./tests/test-pr-workflow-concurrency.sh` still passes (15 passed, 0 failed), so
dropping the filter did not disturb the issue #187 concurrency wiring.

### Full quality gate

`./quality.sh` fails in this container both before and after the change with an
**identical** 45-test failure set (compared against a pristine checkout of the
parent commit). The failures are environmental — PyYAML is not installed, so
every `python3 -c "import yaml"` workflow test reports "YAML syntax errors", and
the macOS/GPU tests cannot run on this Linux host. The change adds one test and
one pass (69 → 70 tests, 24 → 25 passed) and introduces no new failure. CI runs
the same checks on the PR in an environment that has the tooling.

## Test Plan

- Added `tests/test-pr-workflow-branch-filters.sh` — parses every
  `.github/workflows/*.yml` with Ruby's YAML parser, translates each
  `pull_request` branch filter (including `branches-ignore` and `!` negations)
  into an anchored regexp using GitHub's glob semantics (`*` excludes `/`, `**`
  spans it, `?` matches one non-`/` character), and asserts each
  `pull_request`-triggered workflow would run on `milestone/192-example-slug`,
  `Develop` and `main`. Unmodelled pattern characters (`+`, `[`, `]`) fail the
  test loudly instead of passing by default, and a run that finds no
  `pull_request` workflow fails rather than reporting a vacuous pass.
- Re-ran `tests/test-pr-workflow-concurrency.sh`,
  `tests/test-workflow-job-timeouts.sh` and
  `tests/test-workflow-run-strict-mode.sh` — all pass unchanged.
- No existing test was modified or removed.
