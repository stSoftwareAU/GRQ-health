#!/bin/bash
# Test for Issue #189: every multi-line `run:` block in .github/workflows/*.yml
# must start with `set -euo pipefail`.
#
# GitHub's default shell for a `run:` block is `bash -e`, which has neither
# `-u` nor `-o pipefail`. Without pipefail a failed `curl` in
# `curl ... | tar -xz` is invisible — only tar's exit code is checked, so the
# step reports green while the tool it was meant to install is missing or
# truncated. Without `-u` a typo'd variable silently expands to the empty
# string. Both turn a real fault into a green job.
#
# Single-line `run:` blocks are exempt: `bash -e` already fails them on a
# non-zero exit, and there is no pipeline or variable reuse to hide a fault.
#
# The test parses each workflow with a real YAML parser (Ruby's stdlib psych)
# and asserts on the resulting structure rather than grepping raw text.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_DIR="${1:-$SCRIPT_DIR/../.github/workflows}"

REQUIRED_PREFIX="set -euo pipefail"

echo "Testing Issue #189: multi-line run: blocks enable strict mode"
echo "============================================================"
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

if ! command -v ruby >/dev/null 2>&1; then
    echo "  FAIL: ruby is required to parse the workflow YAML but was not found"
    exit 1
fi

# Prints one "<job-id>|<step-label>|<first meaningful line>" line per
# multi-line `run:` step that uses a bash-compatible shell. Newlines inside a
# step name are folded to spaces so one step can never forge two records.
# The first meaningful line skips blank lines and comments, so a leading
# explanatory comment above `set -euo pipefail` is still compliant.
strict_mode_candidates() {
    ruby -ryaml -e '
      wf = YAML.safe_load(File.read(ARGV[0]))
      jobs = wf["jobs"]
      abort "no jobs" unless jobs.is_a?(Hash) && !jobs.empty?
      jobs.each do |job_id, job|
        next unless job.is_a?(Hash)
        steps = job["steps"]
        next unless steps.is_a?(Array)
        steps.each_with_index do |step, index|
          next unless step.is_a?(Hash)
          script = step["run"]
          next unless script.is_a?(String)
          # Only bash-compatible shells are checked; a pwsh or python step
          # has no `set -euo pipefail` to give it.
          shell = step["shell"] || "bash"
          next unless %w[bash sh].include?(shell)
          body = script.strip
          next unless body.include?("\n")
          first = body.lines.map(&:strip).find { |l| !l.empty? && !l.start_with?("#") }
          label = (step["name"] || "step #{index}").to_s.gsub(/\s+/, " ")
          puts [job_id, label, first.to_s].join("|")
        end
      end
    ' "$1"
}

CHECKED=0

for workflow in "$WORKFLOW_DIR"/*.yml; do
    [ -e "$workflow" ] || continue
    name=$(basename "$workflow")

    if ! records=$(strict_mode_candidates "$workflow"); then
        fail_test "$name could not be parsed for run: steps"
        continue
    fi

    while IFS='|' read -r job_id label first_line; do
        [ -n "$job_id" ] || continue
        CHECKED=$((CHECKED + 1))

        if [ "$first_line" = "$REQUIRED_PREFIX" ]; then
            pass_test "$name job '$job_id' step '$label' starts with $REQUIRED_PREFIX"
        else
            fail_test "$name job '$job_id' step '$label' must start with '$REQUIRED_PREFIX', got: '$first_line'"
        fi
    done <<< "$records"
done

if [ "$CHECKED" -eq 0 ]; then
    fail_test "no multi-line run: steps were found to check"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed ($CHECKED multi-line run: steps checked)"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
