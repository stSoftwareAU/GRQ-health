## Summary

`SCR-SEC-ALERTING` found no committed route from a security signal to a human: no `SECURITY.md`, no advisory feed config, and no `if: failure()` notification on either scan job. A red Gitleaks or Semgrep check reached someone only if they happened to look at the PR.

This adds the escalation-document path the issue lists as one of the three accepted fixes — `SECURITY.md` at the repository root — naming who triages a failed security scan, on what clock, and where a vulnerability report goes. It also adds `tests/test-security-policy.sh`, which parses the document and asserts the path is real rather than decorative, and a pointer from the README's existing Security Considerations section.

Closes #205.

**Why the document and not the other two paths.** A `.github/dependabot.yml` would only serve the `github-actions` ecosystem here (the repo has no package manifests), duplicating the weekly `bump-deps.sh` PR on `chore/bump-deps` and losing its quarantine logic — two bump PRs racing on the same pins is a net regression. An `if: failure()` step inside `gitleaks.yml` would edit a workflow the fleet holds to a canonical hardened shape. The escalation document carries no such coupling, and it is where both other paths would have pointed anyway.

## Evidence

Backend/docs change — no web interface to screenshot. The evidence is the test, which fails against the unfixed tree and passes after it:

```
$ ./tests/test-security-policy.sh          # before SECURITY.md existed
  FAIL: SECURITY.md is missing from the repository root
Results: 0 passed, 1 failed

$ ./tests/test-security-policy.sh          # after
  PASS: SECURITY.md exists at the repository root
  PASS: A section covers failing security scans in CI
  PASS: Failed-scan section names the gitleaks scan
  PASS: Failed-scan section names the semgrep scan
  PASS: Failed-scan section names a triage owner by handle
  PASS: Failed-scan section gives an escalation route
  PASS: Reporting section gives a private disclosure route
  PASS: A response-time commitment is stated
  PASS: A supported-versions/scope section is present
Results: 9 passed, 0 failed
```

The routing the document commits to:

```mermaid
flowchart TD
    A[Gitleaks or Semgrep fails] --> B[PR author triages<br/>within 2 business days]
    B --> C{Real finding?}
    C -- no --> D[Fix or narrowly scope the rule,<br/>record why in the PR]
    C -- yes, code not yet merged --> E[Fix on the PR branch<br/>before merge]
    C -- yes, secret was committed --> F[Rotate the credential first,<br/>then open a private advisory]
    F --> G[Label the tracking issue<br/>security + needs-human]
    E --> G
    G --> H[@stSoftwareAU]
```

`markdownlint-cli2` is clean across all 86 markdown files.

## Pre-existing gate failure — not from this change

`./quality.sh` reports 72/73 passing. The one failure is `test-gpu-collection` Test 3, which asserts on `collect_gpu_info` in `run.sh` — a file this branch does not touch (`git status` showed only `README.md`, `SECURITY.md` and `tests/test-security-policy.sh` modified), so the test's inputs are byte-identical to the base commit and the failure is pre-existing on `Develop`. Root cause: the Apple Silicon memory parse picks the decoy `"In use system memory (driver)"=0` key and reports `0 GB in use`. Filed as stSoftwareAU/GRQ-health#207 rather than folded into this change.

## Test Plan

- Added `tests/test-security-policy.sh` (picked up automatically by `quality.sh`'s `tests/test-*.sh` glob). It parses `SECURITY.md` into a heading→body map with `python3` and asserts: the file exists at the root; a section covers failing CI scans; that section names both `gitleaks` and `semgrep`; it names a triage owner by `@handle`; it gives an escalation route (issue/advisory/label); the reporting section gives a private disclosure route; a response-time commitment is stated; and a scope/supported-versions section exists.
- Confirmed red-then-green: run against the tree before `SECURITY.md` was written (1 failure), then after (9 passes).
- `./quality.sh` — 73 tests, 72 pass, 1 pre-existing unrelated failure documented above.
- `markdownlint-cli2` — 0 issues in 86 files.
