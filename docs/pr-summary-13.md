## Summary

Fixed the log button behaviour for multi-user hosts. Previously, when a host had multiple users, the main "View Log" button at the bottom of each host card would still appear, pointing to the generic `node.log` file. This was confusing because:

1. Each user already has their own "Log" button in the user table
2. The generic `node.log` doesn't distinguish between users

**Changes made:**
- The main "View Log" button is now hidden when a host has 2+ users (i.e., when `showUserTable` is true)
- Single-user hosts continue to show the main "View Log" button as before
- Per-user log buttons in the user table remain unchanged
- Version bumped to 1.0.72

## Evidence

This is a UI change affecting the dashboard. The change is conditional based on the number of users:

**Before (multi-user host):**
- User table with per-user log buttons
- PLUS a redundant main "View Log" button

**After (multi-user host):**
- User table with per-user log buttons
- NO main "View Log" button (since it's redundant)

**Single-user hosts** remain unchanged and continue to show the main "View Log" button.

The behaviour can be verified by:
1. Opening the dashboard at `docs/index.html`
2. Looking at a multi-user host (e.g., GRQ-25 with 3 users, GRQ-21 with 2 users)
3. Confirming only the user table log buttons appear
4. Looking at a single-user host (e.g., GRQ-15, GRQ-11)
5. Confirming the main "View Log" button still appears

## Test Plan

- Added `tests/test-log-button-fix.sh` - Shell script that verifies the dashboard.js implementation
- Added `tests/dashboard-log-button.test.html` - Browser-based test page with comprehensive test cases

**Test cases covered:**
1. Single user host should show main View Log button
2. Two user host should NOT show main View Log button
3. Three user host should NOT show main View Log button
4. Host with no users should show main View Log button
5. Multi-user host should have individual log URLs for each user

Run tests with:
```bash
./tests/test-log-button-fix.sh
```

Or open `tests/dashboard-log-button.test.html` in a browser for detailed test output.
