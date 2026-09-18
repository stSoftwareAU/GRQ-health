#!/bin/bash
# Test for Issue #212: run.sh reports the Vibe Coder worker's own state.
#
# The dashboard cannot tell a dead worker from a live worker whose heartbeat
# hooks are failing, because the "Vibe Coder:<host>" row is fed only by a hook
# that runs inside the container. run.sh already runs on the same host as the
# worker, so it reads the worker's own log directory and publishes what it
# finds into the host record.
#
# This test extracts the collector from run.sh and exercises it against
# fabricated log directories, so it is hardware- and worker-independent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"

echo "Testing Issue #212: Vibe Coder worker state collection"
echo "======================================================"
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

if ! command -v jq >/dev/null 2>&1; then
    echo "  SKIP: jq is required for this test"
    exit 0
fi

# Extract the collector and its helpers from run.sh.
eval "$(sed -n '/^vibe_ts_to_epoch()/,/^}/p' "$RUN_SH")"
eval "$(sed -n '/^vibe_log_field()/,/^}/p' "$RUN_SH")"
eval "$(sed -n '/^vibe_count_matches()/,/^}/p' "$RUN_SH")"
eval "$(sed -n '/^vibe_hook_last_stderr()/,/^}/p' "$RUN_SH")"
eval "$(sed -n '/^collect_vibe_coder_state()/,/^}/p' "$RUN_SH")"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# ---------------------------------------------------------------------------
# Fixture: a worker that is alive and succeeding while its success hook fails.
# Line shapes are copied from a real worker log.
# ---------------------------------------------------------------------------
BROKEN_DIR="$WORK_DIR/broken"
mkdir -p "$BROKEN_DIR"
cat > "$BROKEN_DIR/worker.log" <<'EOF'
[2026-09-16 08:58:34Z] ERROR: [s2 stSoftwareAU/VibeCoder#2099] callback failure (/workspace/.grq-vibecoder/callbacks/failure.sh) failed — exit 1, 189.2s
stdout: [grq:failure] reporting health as Vibe Coder:GRQ-25
stderr: [grq:failure] could not fetch https://github.com/stSoftwareAU/GRQ-health.git — gave up after 60s
[2026-09-16 10:14:28Z] ERROR: [s2 stSoftwareAU/GRQ-FX-validation#151] callback success (/workspace/.grq-vibecoder/callbacks/success.sh) failed — exit 1, 189.1s
stdout: [grq:success] reporting health as Vibe Coder:GRQ-25 after stSoftwareAU/GRQ-FX-validation#151
stderr: [grq:success] could not fetch https://github.com/stSoftwareAU/GRQ-health.git — gave up after 60s
[2026-09-16 10:24:47Z] ERROR: [s2 stSoftwareAU/GRQ-FX-validation#150] callback success (/workspace/.grq-vibecoder/callbacks/success.sh) failed — exit 1, 189.1s
stdout: [grq:success] reporting health as Vibe Coder:GRQ-25 after stSoftwareAU/GRQ-FX-validation#150
stderr: [grq:success] clone attempt 3/3 failed (transient): fatal: gave up after 60s
[2026-09-17 22:06:05Z] INFO: [liveness] tick=1 alerted=false live_epoch=1789682384 last_idle_claimed=1789586497 last_productive=1789661507 host=vibe-coder-11053:84
[2026-09-18 00:15:54Z] INFO: fleet-summary: wall=3697s idle=623s claims=2 successes=2 failures=0 skips=0 host=vibe-coder-83770:84
EOF
cat > "$BROKEN_DIR/run_core.log" <<'EOF'
2026-09-16T18:58:59Z work-volume: leaving vibe-agent-state alone - it holds 201 MB, below the 1024 MB reset minimum
2026-09-16T20:46:57Z work-volume: recreating vibe-work - trim refused and 23908 MB free is below the 47148 MB claiming floor (Issue #478)
2026-09-16T20:47:02Z work-volume: the recreate returned 109922 MB free, above the claiming floor (Issue #478)
EOF
printf '%s\n' "$$" > "$BROKEN_DIR/.run.pid"

STATE=$(VIBE_LOG_DIR="$BROKEN_DIR" collect_vibe_coder_state)

echo "Test 1: emitted state is valid JSON..."
if echo "$STATE" | jq . >/dev/null 2>&1; then
    pass_test "collector emits valid JSON"
else
    fail_test "collector emitted invalid JSON: $STATE"
fi

echo ""
echo "Test 2: liveness line populates the three worker timestamps..."
GOT=$(echo "$STATE" | jq -r '[.worker_live_ts, .last_success_ts, .last_claim_ts] | @tsv' 2>/dev/null || echo "")
if [ "$GOT" = "$(printf '1789682384\t1789661507\t1789586497')" ]; then
    pass_test "live_epoch/last_productive/last_idle_claimed parsed — $GOT"
else
    fail_test "expected 1789682384/1789661507/1789586497, got '$GOT'"
fi

echo ""
echo "Test 3: failing heartbeat hooks are counted per event..."
SUCCESS_FAILS=$(echo "$STATE" | jq -r '.hook_failures.success' 2>/dev/null || echo "")
FAILURE_FAILS=$(echo "$STATE" | jq -r '.hook_failures.failure' 2>/dev/null || echo "")
if [ "$SUCCESS_FAILS" = "2" ] && [ "$FAILURE_FAILS" = "1" ]; then
    pass_test "2 success-hook failures, 1 failure-hook failure"
else
    fail_test "expected success=2 failure=1, got success=$SUCCESS_FAILS failure=$FAILURE_FAILS"
fi

echo ""
echo "Test 4: hook failure window start is the first failing hook..."
SINCE=$(echo "$STATE" | jq -r '.hook_failures.since_ts' 2>/dev/null || echo "")
EXPECTED_SINCE=$(vibe_ts_to_epoch "2026-09-16 08:58:34Z")
if [ -n "$SINCE" ] && [ "$SINCE" = "$EXPECTED_SINCE" ] && [ "$SINCE" != "0" ]; then
    pass_test "since_ts is the first failure ($SINCE)"
else
    fail_test "expected since_ts=$EXPECTED_SINCE, got '$SINCE'"
fi

echo ""
echo "Test 5: the most recent hook stderr is captured for the board..."
STDERR_TEXT=$(echo "$STATE" | jq -r '.hook_failures.last_stderr' 2>/dev/null || echo "")
if [[ "$STDERR_TEXT" == *"clone attempt 3/3 failed"* ]]; then
    pass_test "last_stderr carries the newest hook error — $STDERR_TEXT"
else
    fail_test "expected the newest hook stderr, got '$STDERR_TEXT'"
fi

echo ""
echo "Test 6: a live launcher PID is reported alive..."
ALIVE=$(echo "$STATE" | jq -r '.run_pid_alive' 2>/dev/null || echo "")
if [ "$ALIVE" = "true" ]; then
    pass_test "run_pid_alive true for a running PID"
else
    fail_test "expected run_pid_alive=true, got '$ALIVE'"
fi

echo ""
echo "Test 7: the last work-volume reset is reported..."
RESET=$(echo "$STATE" | jq -r '.volume_reset_ts' 2>/dev/null || echo "")
EXPECTED_RESET=$(vibe_ts_to_epoch "2026-09-16T20:46:57Z")
if [ -n "$RESET" ] && [ "$RESET" = "$EXPECTED_RESET" ] && [ "$RESET" != "0" ]; then
    pass_test "volume_reset_ts is the recreate line ($RESET)"
else
    fail_test "expected volume_reset_ts=$EXPECTED_RESET, got '$RESET'"
fi

# ---------------------------------------------------------------------------
# Fixture: healthy worker, no failing hooks, stale PID.
# ---------------------------------------------------------------------------
HEALTHY_DIR="$WORK_DIR/healthy"
mkdir -p "$HEALTHY_DIR"
cat > "$HEALTHY_DIR/worker.log" <<'EOF'
[2026-09-17 20:51:12Z] INFO: [liveness] tick=1 alerted=false live_epoch=1789677950 last_idle_claimed=1789677900 last_productive=1789677950 host=vibe-coder-53149:84
[2026-09-17 20:51:38Z] INFO: fleet-summary: wall=284s idle=284s claims=0 successes=0 failures=0 skips=0 host=vibe-coder-53149:84
EOF
# A PID that cannot be running — the launcher is gone.
printf '%s\n' "999999" > "$HEALTHY_DIR/.run.pid"

HEALTHY_STATE=$(VIBE_LOG_DIR="$HEALTHY_DIR" collect_vibe_coder_state)

echo ""
echo "Test 8: a worker with no failing hooks reports zero failures..."
GOT=$(echo "$HEALTHY_STATE" | jq -r '[.hook_failures.success, .hook_failures.failure, .hook_failures.since_ts, .hook_failures.last_stderr] | @tsv' 2>/dev/null || echo "")
if [ "$GOT" = "$(printf '0\t0\t0\t')" ]; then
    pass_test "no hook failures recorded"
else
    fail_test "expected zeroes and an empty stderr, got '$GOT'"
fi

echo ""
echo "Test 9: a dead launcher PID is reported as not alive..."
ALIVE=$(echo "$HEALTHY_STATE" | jq -r '.run_pid_alive' 2>/dev/null || echo "")
if [ "$ALIVE" = "false" ]; then
    pass_test "run_pid_alive false for a dead PID"
else
    fail_test "expected run_pid_alive=false, got '$ALIVE'"
fi

echo ""
echo "Test 10: a host with no work-volume resets reports 0..."
RESET=$(echo "$HEALTHY_STATE" | jq -r '.volume_reset_ts' 2>/dev/null || echo "")
if [ "$RESET" = "0" ]; then
    pass_test "volume_reset_ts is 0 without a run_core.log"
else
    fail_test "expected volume_reset_ts=0, got '$RESET'"
fi

# ---------------------------------------------------------------------------
# Fixture: no worker installed at all — the collector must stay silent so the
# host record is not padded with a meaningless block.
# ---------------------------------------------------------------------------
echo ""
echo "Test 11: a host with no worker emits nothing..."
EMPTY_DIR="$WORK_DIR/empty"
mkdir -p "$EMPTY_DIR"
EMPTY_STATE=$(VIBE_LOG_DIR="$EMPTY_DIR" collect_vibe_coder_state)
if [ -z "$EMPTY_STATE" ]; then
    pass_test "no output when no worker is installed"
else
    fail_test "expected no output, got '$EMPTY_STATE'"
fi

echo ""
echo "Test 12: a missing log directory emits nothing..."
MISSING_STATE=$(VIBE_LOG_DIR="$WORK_DIR/does-not-exist" collect_vibe_coder_state)
if [ -z "$MISSING_STATE" ]; then
    pass_test "no output when the log directory is absent"
else
    fail_test "expected no output, got '$MISSING_STATE'"
fi

# ---------------------------------------------------------------------------
# Fixture: the worker publishes its own callback-failure streak
# (stSoftwareAU/VibeCoder#2297). That file is authoritative — it survives log
# rotation, which the grep-the-log fallback does not.
# ---------------------------------------------------------------------------
echo ""
echo "Test 13: the published streak file wins over the log scan..."
STREAK_DIR="$WORK_DIR/streaks"
mkdir -p "$STREAK_DIR"
cp "$HEALTHY_DIR/worker.log" "$STREAK_DIR/worker.log"
cat > "$STREAK_DIR/callback-failure-streaks.json" <<'EOF'
{
  "version": 1,
  "updatedAt": "2026-09-18T08:17:47.650Z",
  "events": {
    "success": { "event": "success", "path": "/workspace/.grq-vibecoder/callbacks/success.sh", "streak": 12 },
    "failure": { "event": "failure", "streak": 2 }
  }
}
EOF
STREAK_STATE=$(VIBE_LOG_DIR="$STREAK_DIR" collect_vibe_coder_state)
GOT=$(echo "$STREAK_STATE" | jq -r '[.hook_failures.success, .hook_failures.failure] | @tsv' 2>/dev/null || echo "")
if [ "$GOT" = "$(printf '12\t2')" ]; then
    pass_test "streak file counts used — $GOT"
else
    fail_test "expected 12/2 from the streak file, got '$GOT'"
fi

# ---------------------------------------------------------------------------
# A hook stderr containing quotes and backslashes must not corrupt the JSON.
# ---------------------------------------------------------------------------
echo ""
echo "Test 14: quotes and backslashes in hook stderr stay valid JSON..."
NASTY_DIR="$WORK_DIR/nasty"
mkdir -p "$NASTY_DIR"
cat > "$NASTY_DIR/worker.log" <<'EOF'
[2026-09-16 10:24:47Z] ERROR: [s2 stSoftwareAU/GRQ-FX-validation#150] callback success (/workspace/.grq-vibecoder/callbacks/success.sh) failed — exit 1, 189.1s
stderr: [grq:success] fatal: path "C:\repo" is "broken" — retrying
EOF
NASTY_STATE=$(VIBE_LOG_DIR="$NASTY_DIR" collect_vibe_coder_state)
if echo "$NASTY_STATE" | jq . >/dev/null 2>&1; then
    NASTY_TEXT=$(echo "$NASTY_STATE" | jq -r '.hook_failures.last_stderr')
    if [[ "$NASTY_TEXT" == *'"C:\repo"'* ]]; then
        pass_test "escaped stderr round-trips — $NASTY_TEXT"
    else
        fail_test "stderr lost its quoting: '$NASTY_TEXT'"
    fi
else
    fail_test "quoting broke the JSON: $NASTY_STATE"
fi

# ---------------------------------------------------------------------------
# vibe_ts_to_epoch is the one cross-platform date parser in this path.
# ---------------------------------------------------------------------------
echo ""
echo "Test 15: vibe_ts_to_epoch parses both log timestamp shapes..."
WORKER_EPOCH=$(vibe_ts_to_epoch "2026-09-16 08:58:34Z")
CORE_EPOCH=$(vibe_ts_to_epoch "2026-09-16T08:58:34Z")
if [ "$WORKER_EPOCH" = "1789549114" ] && [ "$CORE_EPOCH" = "1789549114" ]; then
    pass_test "both shapes resolve to 1789549114 UTC"
else
    fail_test "expected 1789549114 for both, got worker='$WORKER_EPOCH' core='$CORE_EPOCH'"
fi

echo ""
echo "Test 16: vibe_ts_to_epoch returns 0 for junk rather than guessing..."
JUNK_EPOCH=$(vibe_ts_to_epoch "not-a-timestamp")
EMPTY_EPOCH=$(vibe_ts_to_epoch "")
if [ "$JUNK_EPOCH" = "0" ] && [ "$EMPTY_EPOCH" = "0" ]; then
    pass_test "unparseable timestamps return 0"
else
    fail_test "expected 0/0, got junk='$JUNK_EPOCH' empty='$EMPTY_EPOCH'"
fi

echo ""
echo "======================================================"
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
