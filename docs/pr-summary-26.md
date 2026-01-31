## Summary

Fixed a bug where multi-user hosts with a recent host-level heartbeat but a stale user heartbeat were incorrectly classified as **critical** instead of **warning**.

**Root cause**: `getHealthStatus()` used `getWorstUserHeartbeatTs()` (the oldest user's heartbeat) for the critical/MIA 24-hour threshold check. If one user hadn't reported in >24 hours, the entire host was marked critical — even if the host itself was seen just minutes ago. The dashboard would confusingly show "Last seen: 1h ago" with a critical status.

**Fix**: The critical/MIA determination now uses the host-level `heart_beat_ts` instead of the worst user heartbeat. Per-user stale detection (which already existed at the warning level) correctly handles individual stale users by returning a **warning** status. This means:
- A host seen recently will never be marked critical due to a single stale user
- Stale users on recently-seen hosts trigger a warning (not critical)
- Hosts that genuinely haven't been heard from in 24+ hours are still marked critical

## Evidence

Unable to generate screenshot: The dashboard requires live `index.json` data and a browser environment. The fix is logic-only in `dashboard.js` and is verified by automated tests.

## Test Plan

- Added `tests/test-critical-vs-warning.sh` with 6 tests verifying:
  1. Critical check references host-level heartbeat
  2. Stale user on recently-seen host triggers warning, not critical
  3. Critical/MIA checks use host heartbeat, not worst user heartbeat
  4. Host heartbeat and user heartbeat are handled separately
  5. Critical section display shows appropriate heartbeat information
  6. `getHealthStatus` logic prevents recently-seen hosts from being critical
- All existing tests continue to pass (9/9 quality checks pass)
