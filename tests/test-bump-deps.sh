#!/bin/bash
# Test for Issue #94: bump-deps.sh script with quarantine and audit gate.
# Verifies the script walks workflow files, classifies actions, applies
# quarantine to external deps, runs the audit gate, and exits cleanly.
#
# All tests use stubbed `gh` and `quality.sh` commands so no network or
# disk-heavy operations run. The fixtures live under a per-test temp dir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
BUMP_SCRIPT="$REPO_ROOT/bump-deps.sh"

echo "Testing Issue #94: bump-deps.sh"
echo "==============================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Test 1: script exists and is executable
if [ -f "$BUMP_SCRIPT" ] && [ -x "$BUMP_SCRIPT" ]; then
    pass_test "bump-deps.sh exists at repo root and is executable"
else
    fail_test "bump-deps.sh is missing or not executable"
    echo ""
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
    exit 1
fi

# Test 2: --help prints usage and exits 0
if HELP_OUT=$("$BUMP_SCRIPT" --help 2>&1) && \
   echo "$HELP_OUT" | grep -qiE 'usage|options|--dry-run' && \
   echo "$HELP_OUT" | grep -qE 'quarantine'; then
    pass_test "--help prints a usage block mentioning --dry-run and quarantine"
else
    fail_test "--help did not print expected usage block"
    echo "$HELP_OUT" | sed 's/^/    /'
fi

# Test 3: shellcheck passes
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x "$BUMP_SCRIPT" >/dev/null 2>&1; then
        pass_test "bump-deps.sh passes shellcheck"
    else
        fail_test "bump-deps.sh has shellcheck warnings"
        shellcheck -x "$BUMP_SCRIPT" 2>&1 | sed 's/^/    /'
    fi
else
    pass_test "shellcheck not installed — skipping"
fi

# ------- Helpers for sandboxed scenarios ---------------------------------

# Build a sandbox containing:
#   - a fake `gh` on PATH that responds from $FAKE_GH_FIXTURES_DIR
#   - a fake `quality.sh` that respects $FAKE_QUALITY_EXIT
#   - a workflow file under .github/workflows/test.yml seeded by the caller
#
# Returns the sandbox path on stdout. Caller is responsible for cleanup.
make_sandbox() {
    local sandbox
    sandbox="$(mktemp -d)"
    mkdir -p "$sandbox/.github/workflows"
    mkdir -p "$sandbox/bin"
    mkdir -p "$sandbox/fixtures"

    # Fake gh — reads the request, looks up a fixture, prints it.
    cat >"$sandbox/bin/gh" <<'GHEOF'
#!/bin/bash
# Fake gh for bump-deps tests. Maps `gh api <path>` -> file under
# $FAKE_GH_FIXTURES_DIR/<sanitised-path>.json.
set -euo pipefail
if [ "${1:-}" != "api" ]; then
    echo "fake gh: unsupported subcommand: $*" >&2
    exit 2
fi
shift
# Strip flags like --jq; we just want the API path.
api_path=""
while [ $# -gt 0 ]; do
    case "$1" in
        --jq|-H) shift 2 || true ;;
        --jq=*|-H=*) shift ;;
        --) shift; api_path="$1"; break ;;
        -*) shift ;;
        *) api_path="$1"; shift ;;
    esac
done
if [ -z "$api_path" ]; then
    echo "fake gh: missing api path" >&2
    exit 2
fi
sanitised="${api_path//\//_}"
fixture="${FAKE_GH_FIXTURES_DIR}/${sanitised}.json"
if [ ! -f "$fixture" ]; then
    echo "fake gh: no fixture for '$api_path' at '$fixture'" >&2
    exit 22
fi
cat "$fixture"
GHEOF
    chmod +x "$sandbox/bin/gh"

    # Fake quality.sh — exits with $FAKE_QUALITY_EXIT (default 0).
    cat >"$sandbox/quality.sh" <<'QEOF'
#!/bin/bash
exit "${FAKE_QUALITY_EXIT:-0}"
QEOF
    chmod +x "$sandbox/quality.sh"

    echo "$sandbox"
}

# Run bump-deps.sh inside a sandbox, with the fake gh on PATH.
run_in_sandbox() {
    local sandbox="$1"; shift
    (
        cd "$sandbox"
        PATH="$sandbox/bin:$PATH" \
        FAKE_GH_FIXTURES_DIR="$sandbox/fixtures" \
        "$BUMP_SCRIPT" "$@"
    )
}

# Write a release fixture: $1=owner $2=repo $3=tag $4=published_at_iso
write_release_fixture() {
    local sandbox="$1" owner="$2" repo="$3" tag="$4" published_at="$5"
    cat >"$sandbox/fixtures/repos_${owner}_${repo}_releases_latest.json" <<JEOF
{"tag_name":"$tag","published_at":"$published_at","name":"$tag"}
JEOF
}

# Write a tag-ref fixture (tag -> commit SHA): $1=sandbox $2=owner $3=repo
# $4=tag $5=sha
write_tag_ref_fixture() {
    local sandbox="$1" owner="$2" repo="$3" tag="$4" sha="$5"
    cat >"$sandbox/fixtures/repos_${owner}_${repo}_git_refs_tags_${tag}.json" <<JEOF
{"ref":"refs/tags/$tag","object":{"type":"commit","sha":"$sha"}}
JEOF
}

# Compute an ISO timestamp $1 hours in the past. Cross-platform.
hours_ago_iso() {
    local hours="$1"
    if date -d "$hours hours ago" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then
        return
    fi
    date -j -u -v-"${hours}"H +%Y-%m-%dT%H:%M:%SZ
}

OLD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
NEW_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# ------- Test 4: happy path (dry-run rewrite plan) -----------------------
SANDBOX=$(make_sandbox)
trap 'rm -rf "$SANDBOX"' EXIT
cat >"$SANDBOX/.github/workflows/test.yml" <<EOF
name: Test
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$OLD_SHA # v4.0.0
EOF
write_release_fixture "$SANDBOX" actions checkout v4.3.1 "$(hours_ago_iso 48)"
write_tag_ref_fixture "$SANDBOX" actions checkout v4.3.1 "$NEW_SHA"

if OUT=$(run_in_sandbox "$SANDBOX" --dry-run 2>&1); then
    if echo "$OUT" | grep -q "actions/checkout" && \
       echo "$OUT" | grep -q "$OLD_SHA" && \
       echo "$OUT" | grep -q "$NEW_SHA" && \
       echo "$OUT" | grep -qE 'v4\.0\.0.*v4\.3\.1'; then
        # Dry-run must NOT modify the file.
        if grep -q "$OLD_SHA" "$SANDBOX/.github/workflows/test.yml"; then
            pass_test "Happy path: --dry-run reports planned bump and does not write"
        else
            fail_test "Happy path: --dry-run mutated the workflow file"
        fi
    else
        fail_test "Happy path: --dry-run output missing expected diff line"
        echo "$OUT" | sed 's/^/    /'
    fi
else
    fail_test "Happy path: --dry-run exited non-zero"
    echo "$OUT" | sed 's/^/    /'
fi
rm -rf "$SANDBOX"

# ------- Test 5: quarantine skips a release younger than the window ------
SANDBOX=$(make_sandbox)
trap 'rm -rf "$SANDBOX"' EXIT
cat >"$SANDBOX/.github/workflows/test.yml" <<EOF
name: Test
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$OLD_SHA # v4.0.0
EOF
# Released only 1 hour ago — quarantine of 24h must skip it.
write_release_fixture "$SANDBOX" actions checkout v4.3.1 "$(hours_ago_iso 1)"
write_tag_ref_fixture "$SANDBOX" actions checkout v4.3.1 "$NEW_SHA"

if OUT=$(run_in_sandbox "$SANDBOX" --dry-run --quarantine-hours 24 2>&1); then
    if echo "$OUT" | grep -qiE 'no bumps|already current|quarantine'; then
        if ! echo "$OUT" | grep -q "$NEW_SHA"; then
            pass_test "Quarantine: a 1h-old release is skipped under 24h quarantine"
        else
            fail_test "Quarantine: a 1h-old release was not skipped"
            echo "$OUT" | sed 's/^/    /'
        fi
    else
        fail_test "Quarantine: expected a no-op or skip message"
        echo "$OUT" | sed 's/^/    /'
    fi
else
    fail_test "Quarantine: script exited non-zero"
    echo "$OUT" | sed 's/^/    /'
fi
rm -rf "$SANDBOX"

# ------- Test 6: no-op when SHA already matches latest -------------------
SANDBOX=$(make_sandbox)
trap 'rm -rf "$SANDBOX"' EXIT
CURRENT_SHA="cccccccccccccccccccccccccccccccccccccccc"
cat >"$SANDBOX/.github/workflows/test.yml" <<EOF
name: Test
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$CURRENT_SHA # v4.3.1
EOF
write_release_fixture "$SANDBOX" actions checkout v4.3.1 "$(hours_ago_iso 48)"
write_tag_ref_fixture "$SANDBOX" actions checkout v4.3.1 "$CURRENT_SHA"

if OUT=$(run_in_sandbox "$SANDBOX" 2>&1); then
    if echo "$OUT" | grep -qE 'OK no bumps -- actions already current'; then
        pass_test "No-op: pinned SHA matches latest in-quarantine release"
    else
        fail_test "No-op: expected 'OK no bumps -- actions already current'"
        echo "$OUT" | sed 's/^/    /'
    fi
else
    fail_test "No-op: script exited non-zero"
    echo "$OUT" | sed 's/^/    /'
fi
rm -rf "$SANDBOX"

# ------- Test 7: audit gate failure exits non-zero with diff -------------
SANDBOX=$(make_sandbox)
trap 'rm -rf "$SANDBOX"' EXIT
cat >"$SANDBOX/.github/workflows/test.yml" <<EOF
name: Test
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$OLD_SHA # v4.0.0
EOF
write_release_fixture "$SANDBOX" actions checkout v4.3.1 "$(hours_ago_iso 48)"
write_tag_ref_fixture "$SANDBOX" actions checkout v4.3.1 "$NEW_SHA"

# Force the audit gate to fail.
EXPORT_FILE="$SANDBOX/quality.sh"
cat >"$EXPORT_FILE" <<'QEOF'
#!/bin/bash
exit 1
QEOF
chmod +x "$EXPORT_FILE"

set +e
OUT=$(run_in_sandbox "$SANDBOX" 2>&1)
RC=$?
set -e
if [ "$RC" -ne 0 ] && \
   echo "$OUT" | grep -qE 'audit|quality' && \
   echo "$OUT" | grep -q "actions/checkout" && \
   echo "$OUT" | grep -q "$NEW_SHA"; then
    pass_test "Audit gate failure: script exits non-zero and prints offending bump"
else
    fail_test "Audit gate failure: rc=$RC, output missing expected text"
    echo "$OUT" | sed 's/^/    /'
fi
rm -rf "$SANDBOX"

# ------- Test 8: internal action skips quarantine ------------------------
SANDBOX=$(make_sandbox)
trap 'rm -rf "$SANDBOX"' EXIT
cat >"$SANDBOX/.github/workflows/test.yml" <<EOF
name: Test
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: stSoftwareAU/some-action@$OLD_SHA # v1.0.0
EOF
# Released 1 hour ago — would normally be quarantined, but stSoftwareAU/* is internal.
write_release_fixture "$SANDBOX" stSoftwareAU some-action v1.1.0 "$(hours_ago_iso 1)"
write_tag_ref_fixture "$SANDBOX" stSoftwareAU some-action v1.1.0 "$NEW_SHA"

if OUT=$(run_in_sandbox "$SANDBOX" --dry-run --quarantine-hours 24 2>&1); then
    if echo "$OUT" | grep -q "stSoftwareAU/some-action" && \
       echo "$OUT" | grep -q "$NEW_SHA" && \
       echo "$OUT" | grep -qE 'v1\.0\.0.*v1\.1\.0'; then
        pass_test "Internal: stSoftwareAU/* action bumps under quarantine"
    else
        fail_test "Internal: expected internal action to bump despite recent release"
        echo "$OUT" | sed 's/^/    /'
    fi
else
    fail_test "Internal: script exited non-zero"
    echo "$OUT" | sed 's/^/    /'
fi
rm -rf "$SANDBOX"

# ------- Test 9: --dry-run on the live repo prints no-op or planned diff -
# Real-world smoke test: the live repo workflows must at least parse
# without the script falling over on syntax. We allow either a no-op or
# a planned-bump exit code 0; what we do not allow is exit non-zero
# from a malformed regex / parse error in the script itself.
# We stub gh and quality so the test is deterministic.

SANDBOX_LIVE=$(mktemp -d)
mkdir -p "$SANDBOX_LIVE/bin" "$SANDBOX_LIVE/fixtures" "$SANDBOX_LIVE/.github/workflows"
cp "$REPO_ROOT/.github/workflows/"*.yml "$SANDBOX_LIVE/.github/workflows/" 2>/dev/null || true
# Stub gh: claim every action is already current at its pinned SHA.
cat >"$SANDBOX_LIVE/bin/gh" <<'GHEOF'
#!/bin/bash
# For the live-smoke test: pretend each release is at tag v0.0.0
# published long ago, with the SHA we extract from the env-passed map.
set -euo pipefail
if [ "${1:-}" != "api" ]; then exit 2; fi
shift
api_path=""
while [ $# -gt 0 ]; do
    case "$1" in
        --jq|-H) shift 2 || true ;;
        --jq=*|-H=*) shift ;;
        -*) shift ;;
        *) api_path="$1"; shift ;;
    esac
done
case "$api_path" in
    repos/*/releases/latest)
        # publish-time long ago so quarantine never blocks
        echo '{"tag_name":"v0.0.0","published_at":"2000-01-01T00:00:00Z","name":"v0.0.0"}'
        ;;
    repos/*/git/refs/tags/*)
        # a deterministic SHA — different from what is actually pinned,
        # so the dry-run plan is non-empty
        echo '{"ref":"refs/tags/v0.0.0","object":{"type":"commit","sha":"0000000000000000000000000000000000000000"}}'
        ;;
    *)
        echo "fake gh: unsupported path '$api_path'" >&2
        exit 22
        ;;
esac
GHEOF
chmod +x "$SANDBOX_LIVE/bin/gh"
cat >"$SANDBOX_LIVE/quality.sh" <<'QEOF'
#!/bin/bash
exit 0
QEOF
chmod +x "$SANDBOX_LIVE/quality.sh"

set +e
LIVE_OUT=$(cd "$SANDBOX_LIVE" && PATH="$SANDBOX_LIVE/bin:$PATH" \
    FAKE_GH_FIXTURES_DIR="$SANDBOX_LIVE/fixtures" \
    "$BUMP_SCRIPT" --dry-run 2>&1)
LIVE_RC=$?
set -e
if [ "$LIVE_RC" -eq 0 ]; then
    pass_test "Live workflow files parse cleanly under --dry-run"
else
    fail_test "Live workflow files: script exited $LIVE_RC under --dry-run"
    echo "$LIVE_OUT" | sed 's/^/    /'
fi
rm -rf "$SANDBOX_LIVE"

trap - EXIT

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
