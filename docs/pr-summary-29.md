## Summary

Fixed false positive error detection in the log viewer. The regex pattern `/Discovery failed/` in `log-viewer.html` was too broad and incorrectly flagged normal operational messages like `"🛍️ Discovery failed to find any improvements, storing failure cache."` as errors.

Replaced with the more specific pattern `/Discovery failed for .+ after .+: Error:/` which only matches actual discovery timeout errors (e.g., `"Discovery failed for creature fa999cac after 240.0s: Error: Discovery timeout"`). Note that the existing `/\bfailed\b.*Error:/` pattern on the next line already catches the "Error:" portion, so the refined pattern serves as a targeted catch for the discovery-specific error format.

## Evidence

This is a backend/log-viewer fix with no visual dashboard changes. The fix was verified by:
- Confirming the old pattern incorrectly matched the issue's example text
- Confirming the new pattern correctly rejects normal operational messages
- Confirming the new pattern still catches real discovery timeout errors
- All 12 classification tests pass, covering both false-positive and true-positive scenarios

## Test Plan

- Added `tests/test-log-viewer-classification.sh` with 12 test cases:
  - `discovery-no-improvements`: Normal "Discovery failed to find any improvements" is NOT flagged (the bug fix)
  - `discovery-timeout-error`: Real discovery timeout errors ARE still flagged
  - `git-sync-normal`: Git sync messages are not flagged
  - `git-branch-normal`: Git branch messages are not flagged
  - `real-error`: ERROR lines are correctly flagged
  - `exception-line`: Exception lines are correctly flagged
  - `warning-emoji`: Warning emoji lines are correctly classified as warnings
  - `stack-trace`: Stack trace lines are correctly classified
  - `failed-with-error`: "failed...Error:" lines are correctly flagged
  - `fatal-error`: Fatal error lines are correctly flagged
  - `failure-emoji`: Failure emoji lines are correctly flagged
  - `c-stack-trace`: C stack trace lines are correctly classified
