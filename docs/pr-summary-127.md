## Summary

Teach `scan_log_errors` in `run.sh` to treat the `[stage-failure-health]
failures=N firstStage=S firstExitCode=C firstHitLine=L` line (emitted by
GRQ#2313) as the authoritative work-success/failure signal, and count
`[reporting-warning] …` lines into a separate `reporting_warning_count`
field on `docs/index.json` so operators can distinguish a healthy run
from a healthy run with transient reporting issues.

Fixes the GRQ-3-sloth misclassification from GRQ#2387 where a
*successful* `discoveryReplay` run was flagged as failed because a noisy
"Task failed with status 2" line followed an authoritative
`failures=0`. Closes #127.

## Evidence

This is a backend/log-parsing change with no UI surface. Verified via
the new `tests/test-stage-failure-health.sh` regression suite plus the
existing `tests/test-scan-log-errors.sh` legacy classifier tests:

```text
Test 1: failures=0 followed by 'Task failed with status 2' classifies as success...
  PASS: GRQ-3-sloth.log fixture classified as success (count=0)
Test 2: failures=3 is classified as failed with stage metadata...
  PASS: failures=3 surfaced as exception_count=3
  PASS: failure summary names firstStage (summary=3 stage failure(s) (first: discoveryReplay exit=42 line=1234))
  PASS: failure summary names firstExitCode
Test 3: [reporting-warning] is counted separately and does not fail the run...
  PASS: reporting-warning present, failures=0 → success
  PASS: reporting_warning_count=2 surfaced
Test 4: Legacy log with stack trace still detected as error...
  PASS: Legacy stack trace still detected (count=1)
Test 5: Legacy clean log still classifies as success...
  PASS: Legacy clean log classified as success
Test 6: failures=0 overrides ⚠️ emoji legacy counts...
  PASS: ⚠️ noise ignored when failures=0

Results: 9 passed, 0 failed
```

Classifier flow:

```mermaid
flowchart TD
    A[node log] --> B{contains<br/>[stage-failure-health]?}
    B -- no --> L[Legacy heuristics<br/>stack traces / ⚠️ / ❌ / etc.]
    B -- yes --> C{failures<br/>field}
    C -- failures=0 --> S[exception_count=0<br/>successful]
    C -- failures>0 --> F[exception_count=N<br/>summary names firstStage / exit / line]
    S --> W{reporting-warning<br/>lines present?}
    F --> W
    W -- count>0 --> R[reporting_warning_count>0<br/>surfaced in index.json]
    W -- count=0 --> J[index.json updated]
    R --> J
    L --> J
```

The pre-existing `test-gitleaks-workflow` failure on the branch
(`Missing gitleaks-action step or GITHUB_TOKEN env`) is unrelated to
this change — confirmed by `git stash` baseline run.

## Test Plan

- Added `tests/test-stage-failure-health.sh` — 9 assertions across 6
  scenarios covering the authoritative signal, legacy fall-back,
  reporting-warning counting, and the GRQ-3-sloth regression fixture.
- Existing `tests/test-scan-log-errors.sh` still passes — legacy
  classifier untouched for logs predating GRQ#2313.
- Ran `./quality.sh < /dev/null` end-to-end — 48/49 pass; the single
  failure is the pre-existing `test-gitleaks-workflow` issue unrelated
  to #127.
- Version bumped `1.1.13 → 1.1.14` and `./update_version.sh` ran to
  propagate to `docs/index.html`, `docs/dashboard.js`, `docs/sw.js`.
