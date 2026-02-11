## Summary

Add HTML escaping to prevent XSS vulnerabilities across the dashboard, log viewer, and simple status page.

**dashboard.js** already had an `escapeHtml()` function and used it consistently across all `innerHTML` assignments — no changes needed there.

**log-viewer.html** had two XSS vulnerabilities:
- Hostname extracted from URL parameter was interpolated into `innerHTML` without escaping (success path, line 167)
- `error.message` and `filePath` were interpolated into `innerHTML` without escaping (error path, lines 184-185)
- Also replaced the DOM-based `escapeHtml` (using `document.createElement`) with the same string-replacement approach used in `dashboard.js` for consistency

**simple.html** had one XSS vulnerability:
- `updateRepoSummary()` used `innerHTML` with unescaped repo names and error messages from `repos.json` (lines 311-315)
- Added `escapeHtml()` function and applied it to all user-controlled data before HTML interpolation

## Evidence

This is a security fix with no visual changes. All changes are in JavaScript logic that escapes special characters (`<`, `>`, `&`, `"`, `'`) before interpolating data into HTML. The dashboard renders identically — only malicious payloads are neutralised.

## Test Plan

- `tests/test-escape-html.sh` — 8 tests verifying `escapeHtml()` function (pre-existing, all pass)
- `tests/test-xss-prevention.sh` — 8 tests verifying `createHostCard()` and `renderRepoHealth()` escape XSS payloads in hostname, os_info, info, location, config_warning, dead host fields, zero handling, and repo names
- `tests/test-xss-log-viewer.sh` — 2 tests verifying log-viewer escapes hostname in both success path (log header) and error path (error display)
- `tests/test-xss-simple-html.sh` — 2 tests verifying simple.html escapes repo names and error messages in summary output

All 16 quality checks pass via `./quality.sh`.
