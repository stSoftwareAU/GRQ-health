#!/bin/bash
# Test for Issue #195: bump-deps.sh must not exit non-zero when the
# upstream registry lookup fails or a prerequisite tool is missing.
#
# A transient GitHub API failure (rate limit, 5xx, network blip) used to
# abort the whole script with status 1, which the worker reads as "the
# bump is bad -- revert it" and, after three consecutive runs, disables
# dependency bumps for the repo entirely. An upstream outage is not a
# defect of this repo: nothing was written, so there is nothing to
# revert. The script must warn loudly, skip the action it could not
# resolve, and exit 0.
#
# All scenarios stub `gh` and `quality.sh` -- no network calls.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUMP_SCRIPT="$REPO_ROOT/bump-deps.sh"

echo "Testing Issue #195: bump-deps.sh upstream-failure resilience"
echo "==========================================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

OLD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
NEW_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# Build a sandbox with a workflow file, a stub quality.sh and a bin dir.
make_sandbox() {
    local sandbox
    sandbox="$(mktemp -d)"
    mkdir -p "$sandbox/.github/workflows" "$sandbox/bin"
    cat >"$sandbox/quality.sh" <<'QEOF'
#!/bin/bash
exit 0
QEOF
    chmod +x "$sandbox/quality.sh"
    echo "$sandbox"
}

write_workflow() {
    local sandbox="$1"; shift
    {
        echo "name: Test"
        echo "on: [push]"
        echo "jobs:"
        echo "  build:"
        echo "    runs-on: ubuntu-latest"
        echo "    steps:"
        local entry
        for entry in "$@"; do
            echo "      - uses: ${entry}"
        done
    } >"$sandbox/.github/workflows/test.yml"
}

# Run the script inside the sandbox with retries made instantaneous.
# Extra environment assignments may be passed in the BUMP_TEST_ENV array,
# so every scenario goes through this one invocation path.
run_in_sandbox() {
    local sandbox="$1"; shift
    (
        cd "$sandbox"
        env PATH="$sandbox/bin:$PATH" \
            BUMP_DEPS_RETRY_DELAY_SECONDS=0 \
            ${BUMP_TEST_ENV[@]+"${BUMP_TEST_ENV[@]}"} \
            "$BUMP_SCRIPT" "$@"
    )
}
BUMP_TEST_ENV=()

# ------- Test 1: release lookup failure is a warned skip, not a failure --
SANDBOX=$(make_sandbox)
trap 'rm -rf "$SANDBOX"' EXIT
write_workflow "$SANDBOX" "actions/checkout@$OLD_SHA # v4.0.0"
cat >"$SANDBOX/bin/gh" <<'GHEOF'
#!/bin/bash
echo "gh: HTTP 403: API rate limit exceeded (https://api.github.com/repos/actions/checkout/releases/latest)" >&2
exit 1
GHEOF
chmod +x "$SANDBOX/bin/gh"

set +e
OUT=$(run_in_sandbox "$SANDBOX" 2>&1)
RC=$?
set -e
if [ "$RC" -eq 0 ] \
   && echo "$OUT" | grep -qE '^OK no bumps' \
   && echo "$OUT" | grep -qi 'warning' \
   && echo "$OUT" | grep -q 'actions/checkout' \
   && grep -q "$OLD_SHA" "$SANDBOX/.github/workflows/test.yml"; then
    pass_test "Release lookup failure: exits 0, warns, leaves the pin untouched"
else
    fail_test "Release lookup failure: rc=$RC, expected exit 0 with a warning"
    echo "$OUT" | sed 's/^/    /'
fi
rm -rf "$SANDBOX"

# ------- Test 2: the underlying gh error is surfaced, not swallowed ------
SANDBOX=$(make_sandbox)
trap 'rm -rf "$SANDBOX"' EXIT
write_workflow "$SANDBOX" "actions/checkout@$OLD_SHA # v4.0.0"
cat >"$SANDBOX/bin/gh" <<'GHEOF'
#!/bin/bash
echo "gh: HTTP 403: API rate limit exceeded" >&2
exit 1
GHEOF
chmod +x "$SANDBOX/bin/gh"

set +e
OUT=$(run_in_sandbox "$SANDBOX" 2>&1)
RC=$?
set -e
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q 'API rate limit exceeded'; then
    pass_test "Diagnosis: the gh error text reaches the operator"
else
    fail_test "Diagnosis: gh's own error text was swallowed (rc=$RC)"
    echo "$OUT" | sed 's/^/    /'
fi
rm -rf "$SANDBOX"

# ------- Test 3: tag resolution failure is a warned skip -----------------
SANDBOX=$(make_sandbox)
trap 'rm -rf "$SANDBOX"' EXIT
write_workflow "$SANDBOX" "actions/checkout@$OLD_SHA # v4.0.0"
cat >"$SANDBOX/bin/gh" <<'GHEOF'
#!/bin/bash
set -uo pipefail
api_path="${2:-}"
case "$api_path" in
    repos/*/releases/latest)
        echo '{"tag_name":"v4.3.1","published_at":"2000-01-01T00:00:00Z"}'
        ;;
    *)
        echo "gh: HTTP 502: Bad gateway" >&2
        exit 1
        ;;
esac
GHEOF
chmod +x "$SANDBOX/bin/gh"

set +e
OUT=$(run_in_sandbox "$SANDBOX" 2>&1)
RC=$?
set -e
if [ "$RC" -eq 0 ] \
   && echo "$OUT" | grep -qi 'warning' \
   && grep -q "$OLD_SHA" "$SANDBOX/.github/workflows/test.yml"; then
    pass_test "Tag resolution failure: exits 0 and leaves the pin untouched"
else
    fail_test "Tag resolution failure: rc=$RC, expected exit 0 with a warning"
    echo "$OUT" | sed 's/^/    /'
fi
rm -rf "$SANDBOX"

# ------- Test 4: a healthy action still bumps when a sibling fails -------
SANDBOX=$(make_sandbox)
trap 'rm -rf "$SANDBOX"' EXIT
write_workflow "$SANDBOX" \
    "actions/checkout@$OLD_SHA # v4.0.0" \
    "actions/setup-node@$OLD_SHA # v4.0.0"
cat >"$SANDBOX/bin/gh" <<GHEOF
#!/bin/bash
set -uo pipefail
api_path="\${2:-}"
case "\$api_path" in
    repos/actions/checkout/*)
        echo "gh: HTTP 403: API rate limit exceeded" >&2
        exit 1
        ;;
    repos/actions/setup-node/releases/latest)
        echo '{"tag_name":"v4.3.1","published_at":"2000-01-01T00:00:00Z"}'
        ;;
    repos/actions/setup-node/git/refs/tags/*)
        echo '{"object":{"type":"commit","sha":"$NEW_SHA"}}'
        ;;
    *)
        echo "fake gh: unsupported path '\$api_path'" >&2
        exit 22
        ;;
esac
GHEOF
chmod +x "$SANDBOX/bin/gh"

set +e
OUT=$(run_in_sandbox "$SANDBOX" 2>&1)
RC=$?
set -e
WF="$SANDBOX/.github/workflows/test.yml"
if [ "$RC" -eq 0 ] \
   && grep -q "actions/setup-node@$NEW_SHA" "$WF" \
   && grep -q "actions/checkout@$OLD_SHA" "$WF" \
   && echo "$OUT" | grep -q 'actions/checkout'; then
    pass_test "Partial outage: the reachable action bumps, the failed one is skipped"
else
    fail_test "Partial outage: rc=$RC, expected setup-node bumped and checkout skipped"
    echo "$OUT" | sed 's/^/    /'
    sed 's/^/    /' "$WF"
fi
rm -rf "$SANDBOX"

# ------- Test 5: a transient failure is retried before being skipped -----
SANDBOX=$(make_sandbox)
trap 'rm -rf "$SANDBOX"' EXIT
write_workflow "$SANDBOX" "actions/checkout@$OLD_SHA # v4.0.0"
cat >"$SANDBOX/bin/gh" <<GHEOF
#!/bin/bash
set -uo pipefail
api_path="\${2:-}"
counter="\${BUMP_TEST_COUNTER:?counter path required}"
attempts=\$(cat "\$counter" 2>/dev/null || echo 0)
case "\$api_path" in
    repos/actions/checkout/releases/latest)
        attempts=\$((attempts + 1))
        echo "\$attempts" >"\$counter"
        if [ "\$attempts" -eq 1 ]; then
            echo "gh: HTTP 502: Bad gateway" >&2
            exit 1
        fi
        echo '{"tag_name":"v4.3.1","published_at":"2000-01-01T00:00:00Z"}'
        ;;
    repos/actions/checkout/git/refs/tags/*)
        echo '{"object":{"type":"commit","sha":"$NEW_SHA"}}'
        ;;
    *)
        echo "fake gh: unsupported path '\$api_path'" >&2
        exit 22
        ;;
esac
GHEOF
chmod +x "$SANDBOX/bin/gh"

set +e
BUMP_TEST_ENV=("BUMP_TEST_COUNTER=$SANDBOX/attempts")
OUT=$(run_in_sandbox "$SANDBOX" 2>&1)
RC=$?
set -e
if [ "$RC" -eq 0 ] && grep -q "actions/checkout@$NEW_SHA" "$SANDBOX/.github/workflows/test.yml"; then
    pass_test "Retry: a one-off 502 is retried and the bump still lands"
else
    fail_test "Retry: rc=$RC, expected the retried lookup to succeed"
    echo "$OUT" | sed 's/^/    /'
fi
# BUMP_DEPS_API_ATTEMPTS=1 must make exactly one call and skip without
# retrying, so the same stub leaves the pin alone.
rm -f "$SANDBOX/attempts"
write_workflow "$SANDBOX" "actions/checkout@$OLD_SHA # v4.0.0"
set +e
BUMP_TEST_ENV=("BUMP_TEST_COUNTER=$SANDBOX/attempts" "BUMP_DEPS_API_ATTEMPTS=1")
OUT=$(run_in_sandbox "$SANDBOX" 2>&1)
RC=$?
set -e
ATTEMPTS=$(cat "$SANDBOX/attempts" 2>/dev/null || echo 0)
if [ "$RC" -eq 0 ] && [ "$ATTEMPTS" -eq 1 ] \
   && grep -q "actions/checkout@$OLD_SHA" "$SANDBOX/.github/workflows/test.yml"; then
    pass_test "Retry: BUMP_DEPS_API_ATTEMPTS=1 makes exactly one call and skips"
else
    fail_test "Retry: attempts=$ATTEMPTS rc=$RC, expected a single un-retried call"
    echo "$OUT" | sed 's/^/    /'
fi
BUMP_TEST_ENV=()
rm -rf "$SANDBOX"

# ------- Test 6: a missing prerequisite tool is a warned no-op ------------
for missing in gh jq; do
    SANDBOX=$(make_sandbox)
    trap 'rm -rf "$SANDBOX"' EXIT
    write_workflow "$SANDBOX" "actions/checkout@$OLD_SHA # v4.0.0"
    # Stub gh so the jq case cannot reach the network if the guard is absent.
    cat >"$SANDBOX/bin/gh" <<'GHEOF'
#!/bin/bash
echo "fake gh: should not be called" >&2
exit 22
GHEOF
    chmod +x "$SANDBOX/bin/gh"

    set +e
    if [ "$missing" = "gh" ]; then
        OUT=$(cd "$SANDBOX" && PATH="$SANDBOX/bin:$PATH" \
            BUMP_DEPS_GH="definitely-not-installed-gh" "$BUMP_SCRIPT" 2>&1)
    else
        OUT=$(cd "$SANDBOX" && PATH="$SANDBOX/bin:$PATH" \
            BUMP_DEPS_JQ="definitely-not-installed-jq" "$BUMP_SCRIPT" 2>&1)
    fi
    RC=$?
    set -e
    if [ "$RC" -eq 0 ] \
       && echo "$OUT" | grep -qE '^OK no bumps' \
       && echo "$OUT" | grep -qi 'warning' \
       && echo "$OUT" | grep -q "definitely-not-installed-$missing"; then
        pass_test "Missing '$missing' on PATH: warned no-op, exit 0"
    else
        fail_test "Missing '$missing' on PATH: rc=$RC, expected a warned no-op"
        echo "$OUT" | sed 's/^/    /'
    fi
    rm -rf "$SANDBOX"
done

# ------- Test 7: a non-JSON body is a warned skip naming jq's error ------
SANDBOX=$(make_sandbox)
trap 'rm -rf "$SANDBOX"' EXIT
write_workflow "$SANDBOX" "actions/checkout@$OLD_SHA # v4.0.0"
cat >"$SANDBOX/bin/gh" <<'GHEOF'
#!/bin/bash
# A rate-limit interstitial reaches jq the same way a real response does.
echo '<html><body>Rate limited</body></html>'
GHEOF
chmod +x "$SANDBOX/bin/gh"

set +e
OUT=$(run_in_sandbox "$SANDBOX" 2>&1)
RC=$?
set -e
if [ "$RC" -eq 0 ] \
   && echo "$OUT" | grep -qi 'unparseable response' \
   && echo "$OUT" | grep -qi 'jq' \
   && grep -q "$OLD_SHA" "$SANDBOX/.github/workflows/test.yml"; then
    pass_test "Non-JSON body: exits 0 and reports jq's own diagnostic"
else
    fail_test "Non-JSON body: rc=$RC, expected a warned skip naming jq's error"
    echo "$OUT" | sed 's/^/    /'
fi
rm -rf "$SANDBOX"

# ------- Test 8: a 404 is settled, so it is not retried -------------------
SANDBOX=$(make_sandbox)
trap 'rm -rf "$SANDBOX"' EXIT
write_workflow "$SANDBOX" "actions/checkout@$OLD_SHA # v4.0.0"
cat >"$SANDBOX/bin/gh" <<'GHEOF'
#!/bin/bash
set -uo pipefail
counter="${BUMP_TEST_COUNTER:?counter path required}"
attempts=$(cat "$counter" 2>/dev/null || echo 0)
echo "$((attempts + 1))" >"$counter"
echo "gh: Not Found (HTTP 404)" >&2
exit 1
GHEOF
chmod +x "$SANDBOX/bin/gh"

set +e
BUMP_TEST_ENV=("BUMP_TEST_COUNTER=$SANDBOX/attempts")
OUT=$(run_in_sandbox "$SANDBOX" 2>&1)
RC=$?
set -e
BUMP_TEST_ENV=()
ATTEMPTS=$(cat "$SANDBOX/attempts" 2>/dev/null || echo 0)
if [ "$RC" -eq 0 ] && [ "$ATTEMPTS" -eq 1 ] && echo "$OUT" | grep -q '404'; then
    pass_test "Permanent 404: called once, not retried, reported"
else
    fail_test "Permanent 404: attempts=$ATTEMPTS rc=$RC, expected a single call"
    echo "$OUT" | sed 's/^/    /'
fi
rm -rf "$SANDBOX"

# ------- Test 9: both missing tools are named in one run -----------------
SANDBOX=$(make_sandbox)
trap 'rm -rf "$SANDBOX"' EXIT
write_workflow "$SANDBOX" "actions/checkout@$OLD_SHA # v4.0.0"

set +e
BUMP_TEST_ENV=("BUMP_DEPS_GH=no-such-gh-binary" "BUMP_DEPS_JQ=no-such-jq-binary")
OUT=$(run_in_sandbox "$SANDBOX" 2>&1)
RC=$?
set -e
BUMP_TEST_ENV=()
if [ "$RC" -eq 0 ] \
   && echo "$OUT" | grep -q 'no-such-gh-binary' \
   && echo "$OUT" | grep -q 'no-such-jq-binary'; then
    pass_test "Both tools missing: a single run names both"
else
    fail_test "Both tools missing: rc=$RC, expected both names in one run"
    echo "$OUT" | sed 's/^/    /'
fi
rm -rf "$SANDBOX"

# ------- Test 10: invalid retry settings are a usage error ---------------
for bad in "BUMP_DEPS_API_ATTEMPTS=abc" "BUMP_DEPS_API_ATTEMPTS=0" \
           "BUMP_DEPS_RETRY_DELAY_SECONDS=-1"; do
    # Run from an empty directory: the setting is validated before any
    # workflow scan, so no fixtures are needed.
    EMPTY_DIR=$(mktemp -d)
    set +e
    OUT=$(cd "$EMPTY_DIR" && env "$bad" "$BUMP_SCRIPT" 2>&1)
    RC=$?
    set -e
    rm -rf "$EMPTY_DIR"
    if [ "$RC" -eq 1 ] && echo "$OUT" | grep -qi 'ERROR'; then
        pass_test "Invalid setting '$bad' is rejected with exit 1"
    else
        fail_test "Invalid setting '$bad': rc=$RC, expected exit 1"
        echo "$OUT" | sed 's/^/    /'
    fi
done

# ------- Test 11: usage errors still exit 1 -------------------------------
set +e
OUT=$("$BUMP_SCRIPT" --no-such-flag 2>&1)
RC=$?
set -e
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -q 'unknown option'; then
    pass_test "Usage error: an unknown flag still exits 1"
else
    fail_test "Usage error: rc=$RC, expected exit 1 for an unknown flag"
    echo "$OUT" | sed 's/^/    /'
fi

trap - EXIT

echo ""
echo "==========================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
