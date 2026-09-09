#!/bin/bash
# Test for Issue #188: every job in .github/workflows/*.yml must declare a
# job-level timeout-minutes.
#
# Without an explicit cap a job inherits GitHub's 360-minute default, so a hung
# step (a stuck apt-get, an unresponsive download, a wedged retry loop) can
# occupy a runner for six hours before GitHub kills it — burning Actions
# minutes and delaying every other queued run for no useful signal.
#
# The test parses each workflow with a real YAML parser (Ruby's stdlib psych —
# available on the GitHub runners and on the monitored hosts without an extra
# install) and asserts on the resulting structure rather than grepping raw text.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_DIR="$SCRIPT_DIR/../.github/workflows"

# Upper bound for a job in this repository. Every job here lints, scans or
# deploys a small static site; anything claiming more than this is a typo or a
# cap so loose it defeats the purpose of setting one.
MAX_TIMEOUT_MINUTES=30

echo "Testing Issue #188: every workflow job declares timeout-minutes"
echo "==============================================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

if ! command -v ruby >/dev/null 2>&1; then
    echo "  FAIL: ruby is required to parse the workflow YAML but was not found"
    exit 1
fi

# Prints one "<job-id>|<timeout-minutes>" line per job in the workflow. The
# timeout field is empty when the job does not declare one.
jobs_of() {
    ruby -ryaml -e '
      wf = YAML.safe_load(File.read(ARGV[0]))
      jobs = wf["jobs"]
      abort "no jobs" unless jobs.is_a?(Hash) && !jobs.empty?
      jobs.each { |id, job| puts "#{id}|#{job.is_a?(Hash) ? job["timeout-minutes"] : nil}" }
    ' "$1"
}

CHECKED=0

for workflow in "$WORKFLOW_DIR"/*.yml; do
    name=$(basename "$workflow")

    if ! ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]))' "$workflow" >/dev/null 2>&1; then
        fail_test "$name is not valid YAML"
        continue
    fi

    if ! job_lines=$(jobs_of "$workflow"); then
        fail_test "$name declares no jobs"
        continue
    fi

    while IFS='|' read -r job_id timeout; do
        [ -n "$job_id" ] || continue
        CHECKED=$((CHECKED + 1))

        if [ -z "$timeout" ]; then
            fail_test "$name job '$job_id' declares no timeout-minutes (inherits the 360-minute default)"
            continue
        fi

        case "$timeout" in
            ''|*[!0-9]*)
                fail_test "$name job '$job_id' timeout-minutes must be a positive integer, got: '$timeout'"
                continue
                ;;
        esac

        if [ "$timeout" -le 0 ]; then
            fail_test "$name job '$job_id' timeout-minutes must be greater than zero, got: '$timeout'"
        elif [ "$timeout" -gt "$MAX_TIMEOUT_MINUTES" ]; then
            fail_test "$name job '$job_id' timeout-minutes of $timeout exceeds the ${MAX_TIMEOUT_MINUTES}-minute cap for this repository"
        else
            pass_test "$name job '$job_id' declares timeout-minutes: $timeout"
        fi
    done <<< "$job_lines"
done

if [ "$CHECKED" -eq 0 ]; then
    fail_test "no workflow jobs were found to check"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed ($CHECKED jobs checked)"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
