## Summary

`get_system_info()` printed its "bc not found" dependency warning to **stdout**.
`update_json` captures that function with `system_info=$(get_system_info)` and
hands the result to `jq --argjson`, so on a host without `bc` the warning was
prepended to the JSON document, `jq` rejected it, and the host's health document
was never updated.

The warning (and the three installation-hint lines with it) now goes to stderr,
so only the JSON document reaches stdout. Closes #214.

Audited every other helper whose stdout is captured together with
`get_system_info`'s — `collect_gpu_info`, `scan_log_errors`,
`collect_vibe_coder_state` and the `vibe_*` helpers: this warning was the only
diagnostic written to stdout. The existing `collect_vibe_coder_state` warning
already used `>&2`.

```mermaid
flowchart LR
    A[update_json] -->|system_info=$(get_system_info)| B[get_system_info]
    B -->|stdout: JSON only| C["jq --argjson info"]
    B -->|stderr: bc warning| D[operator console / log]
    C --> E[docs/index.json updated]
```

## Evidence

Backend/CLI change — no web interface to screenshot. Evidence is the regression
test, run against the unfixed and fixed code.

Before the fix (`bc` masked off the PATH):

```text
Test 1: stdout parses as JSON with bc missing...
  FAIL: stdout is not valid JSON — first line: Warning: bc not found. Some calculations may be simplified.
Test 4: the bc warning is reported on stderr...
  FAIL: bc warning missing from stderr — stderr:
Results: 0 passed, 4 failed
```

After the fix:

```text
Results: 4 passed, 0 failed
```

Full gate: `./quality.sh` → 78 tests, 78 passed, 0 failed (includes the new
test and the version-consistency check after the `1.1.29` → `1.1.30` bump).

## Reproduction

- **symptom** — on a host without `bc`, `get_system_info` prepended
  `Warning: bc not found…` to its JSON, so `jq --argjson` in `update_json`
  failed and the health document was never written
- **status** — `verified` — the regression test was observed failing against
  the unfixed `run.sh` (4/4 assertions red, stdout starting with `Warning:`)
  and passing after the fix
- **regression test** —
  `tests/test-system-info-stdout-json.sh::stdout parses as JSON with bc missing`

## Test Plan

- Added `tests/test-system-info-stdout-json.sh`, which extracts
  `get_system_info` and the helpers it calls from `run.sh`, runs it with `bc`
  (and `ping`, for a hermetic offline run) masked off the PATH, and asserts:
  1. stdout parses with `jq`;
  2. stdout is a single line starting with `{`;
  3. stdout carries none of the dependency-diagnostic wording;
  4. the `bc not found` warning appears on stderr.
- Ran `./quality.sh` (78 tests) — all pass.
- Ran `shellcheck --severity=warning` over the new test — clean.
- Ran `markdownlint-cli2` over the README change — 0 issues.
