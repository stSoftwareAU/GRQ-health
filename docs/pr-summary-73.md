## Summary

Directory listing lines (from `ls -la` output) containing filenames with keywords like
"ERROR" or "Exception" were being incorrectly highlighted as error lines in the log viewer.
For example, files named `.CRISPR-ERROR-Industry 5th percentile.json` were flagged as errors
even though they are just data filenames, not actual errors.

Added a check to detect directory listing lines by their file permission prefix pattern
(e.g., `-rw-r--r--`, `drwxr-xr-x`) and skip error/warning classification for those lines.
This ensures filenames containing error-related keywords are not falsely flagged.

Closes #73.

## Evidence

This is a log viewer classification fix (no visual UI to screenshot). The fix is verified
by 7 new unit tests that confirm:
- Directory listing lines with "ERROR" in filenames are classified as normal
- Directory listing lines with "Exception" in filenames are classified as normal
- Directory listing lines with "WARNING" in filenames are classified as normal
- Real ERROR lines are still correctly flagged as errors

All 26 quality checks pass, including the 19 log viewer classification tests.

## Test Plan

- Added 7 new test cases to `tests/test-log-viewer-classification.sh` (tests 13–19):
  - Test 13: `ls -la` line with `.CRISPR-ERROR-Industry` filename → normal
  - Test 14: `ls -la` line with `.CRISPR-ERROR-Industry 95th percentile V2` filename → normal
  - Test 15: Directory entry with `.CRISPR-ERROR-Insider-Bullish-7-v1` filename → normal
  - Test 16: File entry with `ExceptionReport-2026.txt` filename → normal
  - Test 17: File entry with `WARNING-old-report.csv` filename → normal
  - Test 18: Real `ERROR:` line still correctly flagged as error-line
  - Test 19: `total 47056` line (ls output) still classified as normal
