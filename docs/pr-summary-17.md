# Fix status badge leaking out of host panel

## Summary

Fixed an issue where the health status badge (showing "healthy", "warning", "critical", etc.) could visually overflow beyond the host card boundaries when hostnames are long or when machine type badges are present.

The fix adds proper CSS containment and flex behaviour to ensure the status badge always stays within the host panel:

1. Added `overflow: hidden` to the base `.host-card` class to clip any overflowing content
2. Added `flex-shrink: 0` and `white-space: nowrap` to `.health-status` to prevent the badge from shrinking or wrapping
3. Added `min-width: 0`, `overflow: hidden`, and `text-overflow: ellipsis` to `.host-card h5` to allow the hostname to truncate properly instead of pushing the status badge out

## Evidence

Unable to generate screenshot: Playwright MCP is not available in this environment.

However, the fix can be verified by:
1. Opening the test file `tests/status-overflow.test.html` in a browser - it visually demonstrates the fix with various test cases including long hostnames, machine type badges, and narrow containers
2. Running the shell test `./tests/test-status-overflow.sh` which validates the CSS changes are in place

## Test Plan

- Added `tests/status-overflow.test.html` - Visual browser test that renders host cards with various configurations and verifies the status badge stays within boundaries
- Added `tests/test-status-overflow.sh` - Shell script test that verifies the CSS fix is in place:
  - Test 1: Checks `.host-card` has `overflow: hidden`
  - Test 2: Checks `.health-status` has `flex-shrink: 0`
  - Test 3: Checks `.health-status` has `white-space: nowrap`
  - Test 4: Checks `.host-card h5` has proper flex behaviour with `min-width: 0`
  - Test 5: Verifies overflow handling consistency across card variants

All tests pass via `./quality.sh`.

Fixes #17
