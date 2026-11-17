#!/bin/bash
# Test for Issue #187: PR-triggered check workflows must declare a concurrency
# group so a new push to a PR branch cancels the superseded run.
#
# Without a concurrency block, every push to a PR branch queues another full
# run of each check workflow. That burns runner minutes and lets a stale run
# report after a newer one on the PR checks tab.
#
# The fix keys the group on the workflow and the ref
# (${{ github.workflow }}-${{ github.ref }}) with cancel-in-progress: true, so a
# superseded run of the same workflow on the same branch is cancelled while
# concurrent PRs never cancel each other.
#
# The test parses each workflow with a real YAML parser (Ruby's stdlib psych —
# available on the GitHub runners and on the monitored hosts without an extra
# install) and asserts on the resulting structure rather than grepping raw text.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_DIR="$SCRIPT_DIR/../.github/workflows"

echo "Testing Issue #187: PR-triggered workflows declare a concurrency group"
echo "======================================================================"
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

if ! command -v ruby >/dev/null 2>&1; then
    echo "  FAIL: ruby is required to parse the workflow YAML but was not found"
    exit 1
fi

# Prints "<group>|<cancel-in-progress>" for a workflow that triggers on
# pull_request, or nothing at all when it does not. YAML parses an unquoted
# `on:` key as the boolean true, so both spellings are checked.
concurrency_of() {
    ruby -ryaml -e '
      wf = YAML.safe_load(File.read(ARGV[0]))
      on = wf["on"] || wf[true]
      exit 0 unless on.is_a?(Hash) && on.key?("pull_request")
      c = wf["concurrency"]
      group = c.is_a?(Hash) ? c["group"].to_s : c.to_s
      cancel = c.is_a?(Hash) ? c["cancel-in-progress"].to_s : ""
      puts "#{group}|#{cancel}"
    ' "$1"
}

CHECKED=0

for workflow in "$WORKFLOW_DIR"/*.yml; do
    name=$(basename "$workflow")

    if ! ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]))' "$workflow" >/dev/null 2>&1; then
        fail_test "$name is not valid YAML"
        continue
    fi

    concurrency=$(concurrency_of "$workflow")
    if [ -z "$concurrency" ]; then
        # Not a pull_request-triggered workflow — out of scope for this test.
        continue
    fi

    CHECKED=$((CHECKED + 1))
    group="${concurrency%%|*}"
    cancel="${concurrency#*|}"

    if [ -n "$group" ]; then
        pass_test "$name declares a concurrency group ('$group')"
    else
        fail_test "$name triggers on pull_request but declares no concurrency group"
    fi

    # Keying on github.ref keeps each PR in its own group, so a push to one PR
    # never cancels another PR's in-flight run.
    case "$group" in
        *github.ref*) pass_test "$name concurrency group is keyed on github.ref" ;;
        *) fail_test "$name concurrency group must include github.ref, got: '$group'" ;;
    esac

    if [ "$cancel" = "true" ]; then
        pass_test "$name sets cancel-in-progress: true"
    else
        fail_test "$name must set cancel-in-progress: true, got: '$cancel'"
    fi
done

if [ "$CHECKED" -eq 0 ]; then
    fail_test "no pull_request-triggered workflows were found to check"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed ($CHECKED pull_request workflows checked)"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
