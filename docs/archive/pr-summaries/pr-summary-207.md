## Summary

Apple Silicon hosts reported `0 GB in use` for GPU memory. `collect_gpu_info` in
`run.sh` converted the `ioreg` byte count to GB with `bc -l ... || echo "0"`, so
on any host without `bc` the conversion failed and the `0` fallback was
published as if it were a real reading — a silent failure, not a missing value.

The extraction now converts bytes to GB with shell integer arithmetic, which
removes both the external dependency and the fallback that masked it. The
reported format is unchanged (`2.50 GB in use`, leading zero kept for sub-GB
values), so the dashboard needs no change.

The issue's analysis attributed the fault to the `"In use system memory (driver)"`
decoy key being picked instead of the plain key. That is not what happens: the
existing `grep -o '"In use system memory"=[0-9]\{1,\}'` already excludes the
decoy (verified directly against the fixture line). The decoy remains covered by
the fixture and the tests still assert against it.

Closes #207.

## Evidence

Backend/CLI change — no web interface to screenshot. Evidence is the test run.

Before (unfixed `run.sh`, this container has no `bc`):

```
Test 3: Apple Silicon populates load, memory, model and core count...
  FAIL: Apple Silicon fields parsed — got 45%|0 GB in use|Apple M2 Pro|19
Test 5: GPU memory converts without bc on the PATH...
  FAIL: 2.5 GiB reported in full — expected 2.50 GB in use, got 0 GB in use
Test 6: Sub-gigabyte GPU memory keeps its leading zero...
  FAIL: 0.5 GiB formatted as 0.50 — expected 0.50 GB in use, got 0 GB in use

Passed: 3  Failed: 3
```

After:

```
Test 3: Apple Silicon populates load, memory, model and core count...
  PASS: Apple Silicon fields parsed — 45%|2.50 GB in use|Apple M2 Pro|19
Test 5: GPU memory converts without bc on the PATH...
  PASS: 2.5 GiB reported in full — 2.50 GB in use
Test 6: Sub-gigabyte GPU memory keeps its leading zero...
  PASS: 0.5 GiB formatted as 0.50 — 0.50 GB in use

Passed: 6  Failed: 0
```

Full gate: `./quality.sh` — 74 tests, 74 passed, 0 failed.

## Reproduction

- **symptom** — Apple Silicon hosts show `0 GB in use` for GPU memory on the
  dashboard; `tests/test-gpu-collection.sh` Test 3 fails with
  `45%|0 GB in use|Apple M2 Pro|19`
- **status** — `verified` — Tests 3, 5 and 6 were observed failing against the
  unfixed `run.sh` (restored with `git checkout HEAD -- run.sh`) and passing
  after the fix
- **regression test** — `tests/test-gpu-collection.sh::Test 5: GPU memory converts without bc on the PATH`

## Test Plan

- Added Test 5 to `tests/test-gpu-collection.sh` — asserts `2684354560` bytes
  renders as `2.50 GB in use` on a `PATH` holding only the stubs and the
  coreutils the function needs, deliberately excluding `bc`. Test 3 keeps the
  real `PATH`, so it only caught this on a host that happened to lack `bc`;
  Test 5 pins it everywhere.
- Added Test 6 — asserts a sub-gigabyte value (`536870912`) renders as
  `0.50 GB in use`, covering the leading-zero formatting the old `bc` path
  patched up by hand.
- Existing Tests 1–4 unchanged and still passing; the `(driver)` decoy fixture
  was not weakened.
- `./quality.sh` — 74/74 passed, including `test-shellcheck-clean` and
  `test-version-consistency`.

## Notes for the reviewer

- `VERSION` bumped `1.1.27` → `1.1.28` and `./update_version.sh` run, per the
  README's standing instruction for any code change; that accounts for the
  `docs/index.html`, `docs/dashboard.js` and `docs/sw.js` edits.
- `bc` is still used elsewhere in `run.sh` (disk, memory, CPU speed, load) with
  the same `|| echo "0"` pattern, and remains a documented dependency in the
  README. Those call sites are out of scope for this issue and were left alone.
