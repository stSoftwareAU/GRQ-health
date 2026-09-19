#!/bin/bash
# Test for Issue #211: the heartbeat must commit a bounded log tail, not the
# whole host log, and must not rewrite the destination when the tail is
# unchanged. Both behaviours bound repository growth.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"

echo "Testing Issue #211: bounded log tail committed by the heartbeat"
echo "=============================================================="
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

# Load the real implementation from run.sh (same pattern as the other
# run.sh function tests) so the test exercises shipped code.
eval "$(sed -n '/^copy_log_tail()/,/^}/p' "$RUN_SH")"

if ! type copy_log_tail >/dev/null 2>&1; then
    echo "  FAIL: copy_log_tail is not defined in run.sh"
    exit 1
fi

file_bytes() {
    wc -c < "$1" | tr -d '[:space:]'
}

# --- Test 1: a log smaller than the cap is copied verbatim -----------------
echo "Test 1: small log is copied verbatim..."
SRC="$WORK_DIR/small.log"
DEST="$WORK_DIR/out/small-dest.log"
printf 'line one\nline two\nline three\n' > "$SRC"

if copy_log_tail "$SRC" "$DEST" 65536 >/dev/null; then
    if cmp -s "$SRC" "$DEST"; then
        pass_test "small log copied byte-for-byte"
    else
        fail_test "small log was modified (expected verbatim copy)"
    fi
else
    fail_test "copy_log_tail returned non-zero for a small log"
fi

# --- Test 2: a large log is truncated to the cap ---------------------------
echo "Test 2: large log is truncated to the configured tail size..."
BIG_SRC="$WORK_DIR/big.log"
BIG_DEST="$WORK_DIR/out/big-dest.log"
: > "$BIG_SRC"
{
    echo "OLDEST-LINE-MARKER"
    i=0
    while [ "$i" -lt 4000 ]; do
        echo "filler line $i 0123456789012345678901234567890123456789"
        i=$((i + 1))
    done
    echo "NEWEST-LINE-MARKER"
} > "$BIG_SRC"

SRC_BYTES=$(file_bytes "$BIG_SRC")
CAP=8192
if [ "$SRC_BYTES" -le "$CAP" ]; then
    fail_test "fixture is not larger than the cap (${SRC_BYTES} bytes)"
fi

if copy_log_tail "$BIG_SRC" "$BIG_DEST" "$CAP" >/dev/null; then
    DEST_BYTES=$(file_bytes "$BIG_DEST")
    # The marker line is added on top of the tail, so allow a small margin.
    if [ "$DEST_BYTES" -le $((CAP + 256)) ]; then
        pass_test "truncated log is within the cap (${DEST_BYTES} <= $((CAP + 256)) bytes)"
    else
        fail_test "truncated log is ${DEST_BYTES} bytes, cap is ${CAP}"
    fi

    if grep -q 'NEWEST-LINE-MARKER' "$BIG_DEST"; then
        pass_test "newest lines are retained"
    else
        fail_test "newest lines are missing from the truncated log"
    fi

    if grep -q 'OLDEST-LINE-MARKER' "$BIG_DEST"; then
        fail_test "oldest lines were retained (expected to be dropped)"
    else
        pass_test "oldest lines are dropped"
    fi

    if head -1 "$BIG_DEST" | grep -q 'truncated'; then
        pass_test "truncation is announced in the first line"
    else
        fail_test "no truncation marker in the first line"
    fi

    # Every retained line must be a whole line from the source: the partial
    # line the byte-wise cut produced is dropped.
    SECOND_LINE=$(sed -n '2p' "$BIG_DEST")
    if [ -n "$SECOND_LINE" ] && grep -Fxq "$SECOND_LINE" "$BIG_SRC"; then
        pass_test "first retained line is a complete source line"
    else
        fail_test "first retained line is partial: '${SECOND_LINE}'"
    fi
else
    fail_test "copy_log_tail returned non-zero for a large log"
fi

# --- Test 3: unchanged tail is not rewritten -------------------------------
echo "Test 3: an unchanged tail leaves the destination untouched..."
STABLE_SRC="$WORK_DIR/stable.log"
STABLE_DEST="$WORK_DIR/out/stable-dest.log"
printf 'alpha\nbravo\n' > "$STABLE_SRC"
copy_log_tail "$STABLE_SRC" "$STABLE_DEST" 65536 >/dev/null

# Age the destination so a rewrite is detectable without sleeping.
touch -t 200001010000 "$STABLE_DEST"
BEFORE_MTIME=$(ls -l "$STABLE_DEST" | awk '{print $6, $7, $8}')

OUTPUT=$(copy_log_tail "$STABLE_SRC" "$STABLE_DEST" 65536)
AFTER_MTIME=$(ls -l "$STABLE_DEST" | awk '{print $6, $7, $8}')

if [ "$BEFORE_MTIME" = "$AFTER_MTIME" ]; then
    pass_test "unchanged tail was not rewritten"
else
    fail_test "unchanged tail was rewritten (mtime changed)"
fi

if echo "$OUTPUT" | grep -qi 'unchanged'; then
    pass_test "skip is reported on stdout"
else
    fail_test "skip was not reported: '${OUTPUT}'"
fi

# --- Test 4: a changed tail is written -------------------------------------
echo "Test 4: a changed log is written through..."
printf 'alpha\nbravo\ncharlie\n' > "$STABLE_SRC"
copy_log_tail "$STABLE_SRC" "$STABLE_DEST" 65536 >/dev/null
if grep -q 'charlie' "$STABLE_DEST"; then
    pass_test "new log content reached the destination"
else
    fail_test "new log content was not written"
fi

# --- Test 5: missing source fails loud -------------------------------------
echo "Test 5: a missing source log fails loud..."
set +e
ERR_OUTPUT=$(copy_log_tail "$WORK_DIR/does-not-exist.log" "$WORK_DIR/out/missing.log" 65536 2>&1)
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ]; then
    pass_test "missing source returns non-zero (status ${STATUS})"
else
    fail_test "missing source returned 0"
fi
if echo "$ERR_OUTPUT" | grep -qi 'error'; then
    pass_test "missing source reports an error"
else
    fail_test "missing source produced no error message: '${ERR_OUTPUT}'"
fi

# --- Test 6: an invalid cap fails loud rather than defaulting --------------
echo "Test 6: an invalid tail size fails loud..."
for BAD_CAP in "abc" "0" "-1" ""; do
    set +e
    BAD_OUTPUT=$(copy_log_tail "$STABLE_SRC" "$WORK_DIR/out/bad.log" "$BAD_CAP" 2>&1)
    BAD_STATUS=$?
    set -e
    if [ "$BAD_STATUS" -ne 0 ] && echo "$BAD_OUTPUT" | grep -qi 'error'; then
        pass_test "tail size '${BAD_CAP}' rejected"
    else
        fail_test "tail size '${BAD_CAP}' was accepted (status ${BAD_STATUS})"
    fi
done

# --- Test 6b: an omitted cap uses the shipped default ----------------------
echo "Test 6b: an omitted cap falls back to the shipped default..."
DEFAULT_DEST="$WORK_DIR/out/default-dest.log"
if copy_log_tail "$BIG_SRC" "$DEFAULT_DEST" >/dev/null; then
    DEFAULT_BYTES=$(file_bytes "$DEFAULT_DEST")
    if [ "$DEFAULT_BYTES" -le $((65536 + 256)) ]; then
        pass_test "default cap bounded the published log (${DEFAULT_BYTES} bytes)"
    else
        fail_test "default cap did not bound the published log (${DEFAULT_BYTES} bytes)"
    fi
else
    fail_test "copy_log_tail returned non-zero when the cap was omitted"
fi

# --- Test 7: an empty cap is rejected, not silently defaulted --------------
# run.sh passes "$GRQ_LOG_TAIL_BYTES" straight through, so an operator who
# exports GRQ_LOG_TAIL_BYTES="" must get a loud rejection rather than a
# silent fall-back to the default.
echo "Test 7: an empty cap from the environment is rejected..."
EMPTY_CAP_DEST="$WORK_DIR/out/empty-cap-dest.log"
# Run the shipped assignments with an empty override in the environment.
CAP_CONFIG="$(grep '^GRQ_LOG_TAIL_BYTES_DEFAULT=' "$RUN_SH"; grep '^GRQ_LOG_TAIL_BYTES=' "$RUN_SH")"
EMPTY_CAP_VALUE=$(GRQ_LOG_TAIL_BYTES="" bash -c "${CAP_CONFIG}"'; printf "%s" "$GRQ_LOG_TAIL_BYTES"')
UNSET_CAP_VALUE=$(bash -c "${CAP_CONFIG}"'; printf "%s" "$GRQ_LOG_TAIL_BYTES"')
if [ "$UNSET_CAP_VALUE" != "65536" ]; then
    fail_test "an unset override should take the 65536-byte default (got '${UNSET_CAP_VALUE}')"
fi
if [ -n "$EMPTY_CAP_VALUE" ]; then
    fail_test "run.sh's default expansion swallowed an explicitly empty override"
elif copy_log_tail "$BIG_SRC" "$EMPTY_CAP_DEST" "$EMPTY_CAP_VALUE" >/dev/null 2>&1; then
    fail_test "copy_log_tail accepted an empty cap"
elif [ -f "$EMPTY_CAP_DEST" ]; then
    fail_test "copy_log_tail published a log despite the empty cap"
else
    pass_test "an empty cap is rejected and nothing is published"
fi

# --- Test 8: a tail containing no newline still publishes its content ------
# Dropping the leading partial line is right when the cut lands mid-line, but a
# log whose last GRQ_LOG_TAIL_BYTES hold no newline at all (one very long line)
# has no second line to keep. Publishing only the truncation header there would
# lose the content silently, which is the opposite of what the dashboard needs.
echo "Test 8: a newline-free tail keeps its content..."
NO_NEWLINE_SRC="$WORK_DIR/no-newline.log"
NO_NEWLINE_DEST="$WORK_DIR/out/no-newline-dest.log"
# 12000 bytes on a single line, no trailing newline, against a 4096-byte cap.
awk 'BEGIN { while (i++ < 1000) printf "0123456789AB" }' > "$NO_NEWLINE_SRC"

if copy_log_tail "$NO_NEWLINE_SRC" "$NO_NEWLINE_DEST" 4096 >/dev/null; then
    NO_NEWLINE_BYTES=$(wc -c < "$NO_NEWLINE_DEST" | tr -d '[:space:]')
    NO_NEWLINE_BODY=$(tail -n +2 "$NO_NEWLINE_DEST")
    if [ -z "$NO_NEWLINE_BODY" ]; then
        fail_test "the newline-free tail published a header over no content"
    elif [ "${#NO_NEWLINE_BODY}" -gt 4096 ]; then
        fail_test "the newline-free tail exceeded the cap (${#NO_NEWLINE_BODY} bytes)"
    elif [ "${NO_NEWLINE_SRC:+x}" = "x" ] && ! grep -q "0123456789AB" "$NO_NEWLINE_DEST"; then
        fail_test "the published tail does not contain the source content"
    else
        pass_test "newline-free tail published its last ${#NO_NEWLINE_BODY} bytes (file ${NO_NEWLINE_BYTES} bytes)"
    fi
else
    fail_test "copy_log_tail returned non-zero for a newline-free log"
fi

echo ""
echo "=============================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
