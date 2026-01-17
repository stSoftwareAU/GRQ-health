## Summary

Reduced wasted space in the log viewer by optimising CSS padding, margins, and line spacing. This allows more log content to be visible without scrolling, making it easier to review log files.

### Changes Made

| Element | Before | After | Improvement |
|---------|--------|-------|-------------|
| `.log-container` padding | 20px | 0px | Removed unnecessary inner padding |
| `.log-container` top margin | 80px | 45px | 44% reduction |
| `.log-container` side margins | 20px | 8px | 60% reduction |
| `.log-content` padding | 20px | 8px 10px | 60% reduction |
| `.log-content` line-height | 1.4 | 1.25 | 11% reduction |
| `.log-header` padding | 8px 15px | 6px 10px | 33% reduction |
| `.back-button` size | 20px top/left | 8px top/left | 60% reduction |
| Border radius | 8px | 6px | More compact appearance |
| Border-left on highlighted lines | 3px | 2px | More subtle indicators |

### Mobile Responsiveness

The optimisations extend to mobile viewports (≤768px) with further reduced margins and padding to maximise screen real estate on smaller devices.

## Evidence

Unable to generate screenshot: Playwright MCP is not available in this environment. However, the space improvements can be verified by:

1. Opening the log viewer at `/docs/log-viewer.html?file=GRQ-25/node.log`
2. Comparing the visible log content area before and after this change
3. Running the automated tests which verify the CSS values meet the compact thresholds

### CSS Value Verification

The shell test (`tests/test-log-viewer-space.sh`) verifies:
- `.log-container` padding ≤ 10px ✓
- `.log-container` top margin ≤ 50px ✓
- `.log-container` side margins ≤ 10px ✓
- `.log-content` padding ≤ 12px ✓
- `.log-content` line-height ≤ 1.3 ✓
- `.log-header` padding ≤ 8px ✓

## Test Plan

- Added `tests/log-viewer-space.test.html` - Browser-based visual test for space optimisation
- Added `tests/test-log-viewer-space.sh` - Shell script test that verifies CSS values meet compact thresholds
- All existing tests continue to pass

### Test Results

```
Testing Issue #18: Log viewer space optimisation
=================================================

Test 1: Checking .log-container padding...
  PASS: .log-container padding is 0px (≤ 10px)
Test 2: Checking .log-container margin...
  PASS: .log-container top margin is 45px (≤ 50px)
Test 3: Checking .log-content padding...
  PASS: .log-content padding is 6px (≤ 12px)
Test 4: Checking .log-content line-height...
  PASS: .log-content line-height is  1.25 (≤ 1.3)
Test 5: Checking .log-header padding...
  PASS: .log-header padding is 6px (≤ 8px)
Test 6: Checking .log-container side margins...
  PASS: .log-container side margin is 8px (≤ 10px)

=================================================
All tests passed!
```

Fixes #18
