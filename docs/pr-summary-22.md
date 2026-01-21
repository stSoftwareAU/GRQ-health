# PR Summary - Issue #22: Highlight which user has the warning

## Summary

When a host has multiple users and one or more users are stale (haven't reported within the configured threshold), the warning section now explicitly identifies which specific user(s) are stale, including when they were last seen.

Previously, the warning section would show a host as having a warning but didn't indicate which user was causing the issue. This made it difficult to quickly identify and address the problem.

**Before:** `GRQ-3 - Low CPU utilization: 59.3% (10 cores)`

**After:** `GRQ-3 - Low CPU utilization: 59.3% (10 cores), Stale user: elephant (1d 6h ago)`

## Changes Made

### New Functions in `docs/dashboard.js`

1. **`getStaleUsers(data, nowTs)`** - Identifies which users in a multi-user host are stale
   - Only checks hosts with 2+ users (single-user hosts use the main heartbeat)
   - Returns array of stale users with username, heartbeat timestamp, and hours since last seen
   - Respects per-host `user_stale_hours` threshold (default: 24 hours)

2. **`buildStaleUserWarning(data, nowTs)`** - Builds human-readable warning text
   - Returns empty string if no stale users
   - Includes relative timestamps (e.g., "1d 6h ago")
   - Handles missing heartbeats with "never seen"
   - Uses correct singular/plural grammar ("Stale user:" vs "Stale users:")

### Integration

The warning section in `updateStats()` now calls `buildStaleUserWarning()` to append stale user information to the warning reason.

## Evidence

This is a JavaScript dashboard change. To verify the feature works:

1. Open the dashboard in a browser (`docs/index.html`)
2. If any multi-user host has a stale user, the Warning Hosts section will show which user(s) are stale
3. The stale user information appears at the end of the warning reason with the format: `Stale user: username (Xd Yh ago)`

Screenshot not included as this requires runtime testing with actual stale user data. The feature can be verified by:
- Running the HTML test file: `tests/stale-user-highlight.test.html`
- Running the shell test: `tests/test-stale-user-highlight.sh`
- Opening the dashboard with multi-user hosts where one user is stale

## Test Plan

### Shell Tests (`tests/test-stale-user-highlight.sh`)
- [x] Test 1: `getStaleUsers` function exists in dashboard.js
- [x] Test 2: `buildStaleUserWarning` function exists in dashboard.js
- [x] Test 3: `getStaleUsers` only checks multi-user hosts (>= 2 users)
- [x] Test 4: `buildStaleUserWarning` includes user names
- [x] Test 5: `buildStaleUserWarning` includes timestamp info
- [x] Test 6: `buildStaleUserWarning` handles "never seen" case
- [x] Test 7: Warning section uses `buildStaleUserWarning`
- [x] Test 8: Uses correct singular/plural grammar
- [x] Test 9: Issue #22 is documented in the code

### HTML Tests (`tests/stale-user-highlight.test.html`)
- [x] Single stale user should be identified by name
- [x] Multiple stale users should all be listed
- [x] Warning text should include relative time
- [x] No stale users should return empty warning
- [x] Single-user hosts should not check for stale users
- [x] Missing user heartbeat should show "never seen"
- [x] Custom stale threshold should be respected
- [x] Warning uses singular "user" for one stale user
- [x] Warning uses plural "users" for multiple stale users

### Quality Checks
All existing tests continue to pass:
```
========================
Quality Check Summary
========================
Total tests: 7
Passed: 7
Failed: 0

QUALITY CHECK PASSED
```

## Version

Bumped version from 1.0.75 to 1.0.76
