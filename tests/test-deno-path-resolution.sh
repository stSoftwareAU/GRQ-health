#!/bin/bash
# Test for Issue #198: JS-backed tests must find Deno wherever it is installed.
#
# tests/extract-functions.sh used to hardcode $HOME/.deno/bin/deno, so on any
# host with Deno elsewhere (e.g. /usr/local/bin/deno in the Vibe Coder
# container) 34 of 70 suites died on "No such file or directory". The helper
# now resolves the binary from $DENO, then PATH, then the per-user install,
# and fails with a clear message when none of those exist.
#
# Each scenario runs the real helper in a clean subshell with HOME pointed at
# an empty directory, so the per-user fallback can never satisfy it by
# accident. What is asserted is behaviour: does run_js_test execute, which
# binary did it use, and what happens when there is nothing to find.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Testing Issue #198: Deno resolves from PATH, not a hardcoded per-user path"
echo "========================================================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# A real Deno is needed for the PATH scenario; find one the same way any
# developer would, without the helper under test.
REAL_DENO="$(command -v deno 2>/dev/null || true)"
if [ -z "$REAL_DENO" ] && [ -x "$HOME/.deno/bin/deno" ]; then
    REAL_DENO="$HOME/.deno/bin/deno"
fi
if [ -z "$REAL_DENO" ]; then
    echo "  SKIP: no deno installed on this host; cannot exercise resolution"
    exit 0
fi
REAL_DENO_DIR="$(dirname "$REAL_DENO")"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
EMPTY_HOME="$TMP_DIR/home"
mkdir -p "$EMPTY_HOME"

# Scenario 1: deno is only on PATH (no $HOME/.deno, no $DENO override).
# The Vibe Coder container layout — /usr/local/bin/deno and nothing in $HOME.
OUTPUT="$(env -i HOME="$EMPTY_HOME" PATH="$REAL_DENO_DIR:/usr/bin:/bin" DENO= \
    bash -c 'unset DENO; source "$1/extract-functions.sh" && run_js_test "console.log(\"TEST_RESULT:path:PASS:ran via \" + Deno.execPath())"' \
    _ "$SCRIPT_DIR" 2>&1 || true)"
if echo "$OUTPUT" | grep -q '^TEST_RESULT:path:PASS:'; then
    pass "deno found on PATH when \$HOME/.deno is absent"
else
    fail "deno on PATH was not used when \$HOME/.deno is absent"
    echo "$OUTPUT" | sed 's/^/    /'
fi

# Scenario 2: an explicit $DENO override wins over PATH.
# A shim records that it was invoked, then delegates to the real binary.
SHIM_DIR="$TMP_DIR/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/deno" <<SHIM
#!/bin/bash
echo "SHIM_INVOKED"
exec "$REAL_DENO" "\$@"
SHIM
chmod +x "$SHIM_DIR/deno"
OUTPUT="$(env -i HOME="$EMPTY_HOME" PATH="$REAL_DENO_DIR:/usr/bin:/bin" DENO="$SHIM_DIR/deno" \
    bash -c 'source "$1/extract-functions.sh" && run_js_test "console.log(\"TEST_RESULT:override:PASS:ok\")"' \
    _ "$SCRIPT_DIR" 2>&1 || true)"
if echo "$OUTPUT" | grep -q '^SHIM_INVOKED$' && echo "$OUTPUT" | grep -q '^TEST_RESULT:override:PASS:'; then
    pass "\$DENO override is honoured ahead of PATH"
else
    fail "\$DENO override was not used"
    echo "$OUTPUT" | sed 's/^/    /'
fi

# Scenario 3: nothing resolves. The helper must exit non-zero with a clear
# message, not a bare "No such file or directory" from the shell.
set +e
OUTPUT="$(env -i HOME="$EMPTY_HOME" PATH="/usr/bin:/bin" \
    bash -c 'unset DENO; source "$1/extract-functions.sh"; echo "STILL_RUNNING"' \
    _ "$SCRIPT_DIR" 2>&1)"
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ] && echo "$OUTPUT" | grep -q 'deno not found' && ! echo "$OUTPUT" | grep -q 'STILL_RUNNING'; then
    pass "missing deno fails loud with a clear message (exit $STATUS)"
else
    fail "missing deno did not fail loud (exit $STATUS)"
    echo "$OUTPUT" | sed 's/^/    /'
fi
if echo "$OUTPUT" | grep -q 'No such file or directory'; then
    fail "missing deno still leaks a shell 'No such file or directory' error"
else
    pass "no shell 'No such file or directory' noise when deno is missing"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
