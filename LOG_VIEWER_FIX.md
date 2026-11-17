# Log Viewer Error Highlighting Fix

## The Issue

GRQ-3 was correctly detecting and reporting 4 errors in the health monitoring system:
- `"exception_count": 4`
- `"exception_summary": "4 errors found (4 stack traces)"`

However, when viewing the log via the PWA, these errors were **not highlighted**, making them difficult to spot.

## The Root Cause

The 4 errors in the GRQ-3 log are "Discovery timeout" failures:

1. **Line 92**: `[Neat] Discovery failed for creature fa999cac after 240.0s: Error: Discovery timeout...`
2. **Line 146**: `[Neat] Discovery failed for creature e2a8b04a after 300.1s: Error: Discovery timeout...`
3. **Line 195**: `[Neat] Discovery failed for creature f8a3951f after 360.0s: Error: Discovery timeout...`
4. **Line 277**: `[Neat] Discovery failed for creature 0dc7e6c1 after 1440.2s: Error: Discovery timeout...`

Each of these has a stack trace below it starting with `at https://jsr.io/@stsoftware/neat-ai/...`

### Why They Were Counted But Not Highlighted

The **health monitoring script** (`run.sh`) correctly detected these errors because it:
- Searches for lines containing "Error", "Exception", or "MEMETIC"
- That precede stack traces (lines starting with whitespace + "at ")

The **log viewer** (`log-viewer.html`) was NOT highlighting them because it only looked for:
- "ERROR" (all caps)
- "Exception"
- Lines **starting** with "Error:" (not containing it)

Since the Discovery failed lines have "Error:" in the middle (not at the start), they weren't highlighted.

## The Fix

Updated `docs/log-viewer.html` to detect errors more accurately without false positives:

```javascript
// Before: Only detected "ERROR", "Exception", or lines starting with "Error:"
if (line.includes('ERROR') || line.includes('Exception') || line.startsWith('Error:'))

// After: Detects actual errors while avoiding false positives from training metrics
if (line.includes('ERROR') || 
    line.includes('Exception') || 
    line.startsWith('Error:') ||           // Lines that start with "Error:"
    /Discovery failed/.test(line) ||        // Discovery timeout failures
    /\bfailed\b.*Error:/.test(line))        // Lines with "failed" followed by "Error:"
```

**Key improvement**: Uses `line.startsWith('Error:')` instead of `line.includes('Error:')` to avoid flagging normal training messages like:
- `Trained fa999cac Score: 0.4038895022538375, Error: 0.5961027022051043 -> 0.5961094691012`

These training messages contain "Error:" as a metric name, not an actual error.

Also improved warning detection to include the ⚠️ emoji.

## Version Update

Incremented version from `1.0.33` → `1.0.36` to force PWA cache refresh.

## Result

When you now view the GRQ-3 log in the PWA:
1. The 4 "Discovery failed" error lines will be **highlighted in red** with a red left border
2. The stack traces below them will be **highlighted in pink**
3. The log viewer will automatically **scroll to the first error** when the log loads
4. The PWA will automatically refresh to get the new version

## Notes on the Errors Themselves

These "Discovery timeout" errors indicate that the training/discovery process for these neural network creatures took longer than expected and timed out. These **ARE actual errors** that should be investigated:

- Line 92: Discovery failed for fa999cac after 240.0s (4 minute timeout)
- Line 146: Discovery failed for e2a8b04a after 300.1s (5 minute timeout)  
- Line 195: Discovery failed for f8a3951f after 360.0s (6 minute timeout)
- Line 277: Discovery failed for 0dc7e6c1 after 1440.2s (24 minute timeout)

While the system continued to function and complete its work (as seen by the successful generations and evolution progress), these timeouts indicate potential issues with the discovery process that may need optimization.

**Note**: Normal training messages like "Trained fa999cac Score: 0.4038895022538375, Error: 0.5961027022051043 -> 0.5961094691012" are expected and should NOT be flagged as errors.

