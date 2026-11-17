#!/bin/bash
# Test for Issue #214: get_system_info() must emit JSON and nothing else on
# stdout. Its stdout is captured by update_json (system_info=$(get_system_info))
# and handed to `jq --argjson`, so any diagnostic printed to stdout corrupts the
# health document. Diagnostics belong on stderr.
#
# The "bc not found" warning is the known offender, so the test runs
# get_system_info with `bc` masked off the PATH and asserts stdout still parses
# as JSON while the warning lands on stderr.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"

echo "Testing Issue #214: get_system_info stdout is pure JSON"
echo "======================================================"
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Extract get_system_info and every run.sh function it calls. The nested
# escape_json() helper is closed by an indented brace, so the `^}` terminator
# still matches only the end of each top-level function.
for fn in vibe_ts_to_epoch vibe_log_field vibe_count_matches \
          vibe_hook_last_stderr collect_vibe_coder_state collect_gpu_info \
          scan_log_errors get_system_info; do
    fn_src=$(sed -n "/^${fn}()/,/^}/p" "$RUN_SH")
    if [ -z "$fn_src" ]; then
        echo "FATAL: could not extract ${fn}() from $RUN_SH"
        exit 1
    fi
    eval "$fn_src"
done

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/home/logs"

# Build a PATH without `bc` so the dependency warning always fires, and without
# `ping` so the network probe cannot reach out or stall in a sandbox.
STUB_BIN="$WORK_DIR/bin"
mkdir -p "$STUB_BIN"
IFS=: read -r -a PATH_DIRS <<< "$PATH"
for dir in "${PATH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    for entry in "$dir"/*; do
        [ -x "$entry" ] || continue
        name=${entry##*/}
        case "$name" in
            bc|ping) continue ;;
        esac
        [ -e "$STUB_BIN/$name" ] || ln -s "$entry" "$STUB_BIN/$name" 2>/dev/null || true
    done
done

if PATH="$STUB_BIN" command -v bc >/dev/null 2>&1; then
    echo "FATAL: bc is still reachable on the masked PATH"
    exit 1
fi

STDOUT_FILE="$WORK_DIR/stdout"
STDERR_FILE="$WORK_DIR/stderr"

# get_system_info probes the host, so unreadable paths and missing tools are
# expected here; `set +eu` keeps those from aborting the test harness itself.
(
    set +eu
    PATH="$STUB_BIN"
    HOME="$WORK_DIR/home"
    # BASE_DIR is read by the eval'd get_system_info, which shellcheck cannot see.
    # shellcheck disable=SC2034
    BASE_DIR="$WORK_DIR"
    HOSTNAME="test-host"
    get_system_info
) > "$STDOUT_FILE" 2> "$STDERR_FILE" || true

echo "Test 1: stdout parses as JSON with bc missing..."
if command -v jq >/dev/null 2>&1; then
    if jq . "$STDOUT_FILE" > /dev/null 2>&1; then
        pass_test "stdout is valid JSON"
    else
        fail_test "stdout is not valid JSON — first line: $(head -1 "$STDOUT_FILE")"
    fi
else
    echo "  SKIP: jq not installed"
fi

echo "Test 2: stdout carries a single line and starts with '{'..."
STDOUT_LINES=$(wc -l < "$STDOUT_FILE" | tr -d ' ')
FIRST_CHAR=$(head -c 1 "$STDOUT_FILE")
if [ "$STDOUT_LINES" = "1" ] && [ "$FIRST_CHAR" = "{" ]; then
    pass_test "stdout is one JSON line"
else
    fail_test "stdout has $STDOUT_LINES line(s) starting with '$FIRST_CHAR' — first line: $(head -1 "$STDOUT_FILE")"
fi

# The JSON itself carries a config_warning field, so match the dependency
# diagnostic's own wording rather than the word "warning".
DIAGNOSTIC_RE='bc not found|^Installation:|brew install|apt-get install|yum install'
echo "Test 3: stdout carries no diagnostic text..."
if grep -qE "$DIAGNOSTIC_RE" "$STDOUT_FILE"; then
    fail_test "diagnostic text leaked to stdout — $(grep -E "$DIAGNOSTIC_RE" "$STDOUT_FILE" | head -1)"
else
    pass_test "no diagnostic text on stdout"
fi

echo "Test 4: the bc warning is reported on stderr..."
if grep -q 'bc not found' "$STDERR_FILE"; then
    pass_test "bc warning written to stderr"
else
    fail_test "bc warning missing from stderr — stderr: $(head -3 "$STDERR_FILE")"
fi

echo ""
echo "======================================================"
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
