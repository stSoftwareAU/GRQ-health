#!/bin/bash
# Test for Issue #192: PR-triggered check workflows must run on milestone/*
# pull requests.
#
# GitHub Actions branch-filter globs treat `*` as matching zero or more
# characters *excluding* `/`, so `branches: ["*"]` silently skips every PR whose
# target branch contains a slash. The planning-delivery workflow merges
# sub-issue PRs into a shared `milestone/<slug>` branch, so those PRs merged
# with none of the repo's check workflows running on them.
#
# Rather than grepping the YAML for a particular spelling of the fix, this test
# models GitHub's own filter-pattern semantics and asks the question that
# matters: given each workflow's branch filter, would the workflow run on a PR
# targeting `milestone/<slug>`? Dropping the filter, widening it, or any other
# correct spelling passes; only a filter that actually excludes milestone
# branches fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_DIR="$SCRIPT_DIR/../.github/workflows"

echo "Testing Issue #192: PR workflows run on milestone/* branches"
echo "==========================================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

if ! command -v ruby >/dev/null 2>&1; then
    echo "  FAIL: ruby is required to parse the workflow YAML but was not found"
    exit 1
fi

# Branches a check workflow must run on. The milestone branch is the one the
# `*` glob silently excluded; the other two guard against a fix that widens the
# filter so far it drops the normal targets.
CANDIDATE_BRANCHES=("milestone/192-example-slug" "Develop" "main")

# Prints one "<branch>|run|skip" line per candidate branch for a workflow that
# triggers on pull_request, or nothing at all when it does not. Exits non-zero
# with a message on any filter pattern whose semantics this matcher does not
# model, so an unmodelled pattern fails loudly instead of passing by default.
would_run_on() {
    ruby -ryaml -e '
      # Translates a GitHub Actions filter pattern into an anchored regexp.
      # `*` matches any character except `/`; `**` matches across `/`; `?`
      # matches a single non-`/` character. Everything else is a literal.
      def to_regex(pattern)
        out = ""
        i = 0
        while i < pattern.length
          c = pattern[i]
          case c
          when "*"
            if pattern[i + 1] == "*"
              out << ".*"
              i += 2
              next
            end
            out << "[^/]*"
          when "?"
            out << "[^/]"
          when "+", "[", "]"
            warn "unsupported filter pattern character #{c.inspect} in #{pattern.inspect}"
            exit 2
          else
            out << Regexp.escape(c)
          end
          i += 1
        end
        Regexp.new("\\A#{out}\\z")
      end

      # A branch runs when it matches at least one positive pattern and no
      # negative (`!`-prefixed) one. An absent filter list means "every branch".
      def matches?(patterns, branch)
        return true if patterns.nil?
        positive = patterns.reject { |p| p.start_with?("!") }
        negative = patterns.select { |p| p.start_with?("!") }.map { |p| p[1..] }
        return false unless positive.any? { |p| to_regex(p).match?(branch) }
        negative.none? { |p| to_regex(p).match?(branch) }
      end

      wf = YAML.safe_load(File.read(ARGV[0]))
      on = wf["on"] || wf[true]   # YAML parses an unquoted `on:` key as true
      exit 0 unless on.is_a?(Hash) && on.key?("pull_request")

      pr = on["pull_request"] || {}
      include_patterns = pr["branches"]
      ignore_patterns = pr["branches-ignore"]

      ARGV[1..].each do |branch|
        runs = matches?(include_patterns, branch) &&
               !(ignore_patterns && matches?(ignore_patterns, branch))
        puts "#{branch}|#{runs ? "run" : "skip"}"
      end
    ' "$@"
}

CHECKED=0

for workflow in "$WORKFLOW_DIR"/*.yml; do
    name=$(basename "$workflow")

    if ! ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]))' "$workflow" >/dev/null 2>&1; then
        fail_test "$name is not valid YAML"
        continue
    fi

    if ! results=$(would_run_on "$workflow" "${CANDIDATE_BRANCHES[@]}"); then
        fail_test "$name uses a branch filter pattern this test cannot evaluate"
        continue
    fi

    if [ -z "$results" ]; then
        # Not a pull_request-triggered workflow — out of scope for this test.
        continue
    fi

    CHECKED=$((CHECKED + 1))

    while IFS='|' read -r branch verdict; do
        [ -n "$branch" ] || continue
        if [ "$verdict" = "run" ]; then
            pass_test "$name runs on a PR targeting '$branch'"
        else
            fail_test "$name skips a PR targeting '$branch'; its branch filter excludes it"
        fi
    done <<< "$results"
done

if [ "$CHECKED" -eq 0 ]; then
    fail_test "no pull_request-triggered workflows were found to check"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed ($CHECKED pull_request workflows checked)"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
