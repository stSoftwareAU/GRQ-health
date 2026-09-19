#!/bin/bash
# Test for Issue #211: run.sh must commit only a bounded tail of the host
# log, never the whole file (whole-log commits put ~865 MB of history into
# a 32 MB repository).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"
HELPER="$SCRIPT_DIR/../helpers/log-tail.sh"

echo "Testing Issue #211: only the log tail is published"
echo "=================================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() {
    echo "  PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail_test() {
    echo "  FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# shellcheck disable=SC1090
. "$HELPER"

file_size() {
    wc -c < "$1" | tr -d '[:space:]'
}

# Test 1: default limit is 64 KB
unset GRQ_LOG_TAIL_BYTES
if [ "$(grq_log_tail_bytes)" = "65536" ]; then
    pass_test "default tail limit is 65536 bytes"
else
    fail_test "default tail limit is $(grq_log_tail_bytes), expected 65536"
fi

# Test 2: invalid overrides fall back to the default
for bad in "abc" "0" "-5" ""; do
    if [ "$(GRQ_LOG_TAIL_BYTES="$bad" grq_log_tail_bytes)" = "65536" ]; then
        pass_test "override '$bad' falls back to the default"
    else
        fail_test "override '$bad' gave $(GRQ_LOG_TAIL_BYTES="$bad" grq_log_tail_bytes)"
    fi
done

# Test 3: a small log is copied verbatim
printf 'line one\nline two\n' > "$WORK_DIR/small.log"
grq_copy_log_tail "$WORK_DIR/small.log" "$WORK_DIR/small.out"
if cmp -s "$WORK_DIR/small.log" "$WORK_DIR/small.out"; then
    pass_test "log under the limit is copied verbatim"
else
    fail_test "log under the limit was altered"
fi

# Test 4: a large log is truncated to the limit, keeps its newest lines,
# starts on a line boundary and carries the truncation marker
for i in $(seq 1 20000); do
    echo "log line number $i with some padding to make it longer"
done > "$WORK_DIR/big.log"
export GRQ_LOG_TAIL_BYTES=4096
grq_copy_log_tail "$WORK_DIR/big.log" "$WORK_DIR/big.out"

out_size=$(file_size "$WORK_DIR/big.out")
# limit + the single marker line
if [ "$out_size" -le $((4096 + 200)) ]; then
    pass_test "large log truncated to the limit (${out_size} bytes)"
else
    fail_test "large log published ${out_size} bytes, limit 4096"
fi

if [ "$(tail -n 1 "$WORK_DIR/big.out")" = "$(tail -n 1 "$WORK_DIR/big.log")" ]; then
    pass_test "truncated log keeps the newest line"
else
    fail_test "truncated log lost the newest line"
fi

if head -n 1 "$WORK_DIR/big.out" | grep -q '^\[log truncated by run.sh: showing the last 4 KB of '; then
    pass_test "truncated log starts with the marker line"
else
    fail_test "marker line missing: $(head -n 1 "$WORK_DIR/big.out")"
fi

if sed -n '2p' "$WORK_DIR/big.out" | grep -q '^log line number [0-9]* with some padding to make it longer$'; then
    pass_test "truncated log starts on a line boundary"
else
    fail_test "first kept line is partial: $(sed -n '2p' "$WORK_DIR/big.out")"
fi

if grep -q '^log line number 1 ' "$WORK_DIR/big.out"; then
    fail_test "oldest line survived truncation"
else
    pass_test "oldest lines are dropped"
fi

# Test 5: a single enormous line is kept rather than emptied
head -c 10000 /dev/zero | tr '\0' 'x' > "$WORK_DIR/oneline.log"
grq_copy_log_tail "$WORK_DIR/oneline.log" "$WORK_DIR/oneline.out"
if [ "$(sed -n '2p' "$WORK_DIR/oneline.out" | tr -d '\n' | wc -c | tr -d '[:space:]')" = "4096" ]; then
    pass_test "tail without a newline is kept"
else
    fail_test "tail without a newline was mangled"
fi
unset GRQ_LOG_TAIL_BYTES

# Test 6: missing source fails and leaves the destination untouched
echo "previous" > "$WORK_DIR/keep.out"
if grq_copy_log_tail "$WORK_DIR/missing.log" "$WORK_DIR/keep.out"; then
    fail_test "missing source reported success"
elif [ "$(cat "$WORK_DIR/keep.out")" = "previous" ]; then
    pass_test "missing source fails and leaves destination untouched"
else
    fail_test "missing source clobbered the destination"
fi

# Test 7: no temp files left behind
if find "$WORK_DIR" -name '*.tmp.*' | grep -q .; then
    fail_test "temp files left behind"
else
    pass_test "no temp files left behind"
fi

# Test 8: run.sh uses the helper and never copies the whole log
# The patterns below are literal run.sh source text, not expansions.
# shellcheck disable=SC2016
if grep -q 'grq_copy_log_tail "\$LOG_SRC" "\$LOG_DEST_USER"' "$RUN_SH"; then
    pass_test "run.sh publishes the log through grq_copy_log_tail"
else
    fail_test "run.sh does not call grq_copy_log_tail"
fi

# shellcheck disable=SC2016
if grep -q 'cp "\$LOG_SRC"' "$RUN_SH"; then
    fail_test "run.sh still copies the whole log"
else
    pass_test "run.sh no longer copies the whole log"
fi

if grep -q 'helpers/log-tail.sh' "$RUN_SH"; then
    pass_test "run.sh sources helpers/log-tail.sh"
else
    fail_test "run.sh does not source helpers/log-tail.sh"
fi

echo ""
echo "=================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
