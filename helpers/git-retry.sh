#!/bin/bash
# Git retry helpers for graceful handling of GitHub rate limits and
# transient network failures. Sourced by run.sh and helpers/repos.sh.
#
# Exposes:
#   grq_timeout_cmd          — echoes the timeout binary (gtimeout/timeout)
#                              or empty if neither is installed.
#   grq_git_timeout_secs     — echoes the per-git-call timeout (default 120).
#                              Override via GRQ_GIT_TIMEOUT_OVERRIDE.
#   grq_backoff_delays       — echoes the space-separated backoff delays
#                              (default "1 4 16"). Override via
#                              GRQ_PUSH_RETRY_DELAYS_OVERRIDE for tests.
#   grq_max_push_attempts    — echoes the max push attempts (default 3).
#                              Override via GRQ_PUSH_MAX_ATTEMPTS.
#   grq_run_git              — runs `git "$@"` wrapped in the timeout helper
#                              (when available). Caller controls redirections.
#   grq_is_rate_limit_error  — given stderr text on stdin, returns 0 if the
#                              text matches a GitHub rate-limit response.
#   grq_rate_limit_sleep_secs — when called after a detected rate limit,
#                              echoes how many seconds to sleep before the
#                              next attempt. Honours
#                              GRQ_RATE_LIMIT_SLEEP_OVERRIDE for tests; if
#                              `gh` is available it queries
#                              `gh api rate_limit` for the reset window.
#   grq_recover_to_remote    — discards local commits/working-tree changes
#                              on the current branch by `git reset --hard
#                              origin/<branch>` + `git clean -fd`. Caller
#                              must already be in the repo directory.

# Resolve timeout binary cross-platform.
grq_timeout_cmd() {
    if command -v gtimeout >/dev/null 2>&1; then
        echo "gtimeout"
    elif command -v timeout >/dev/null 2>&1; then
        echo "timeout"
    else
        echo ""
    fi
}

grq_git_timeout_secs() {
    echo "${GRQ_GIT_TIMEOUT_OVERRIDE:-120}"
}

grq_backoff_delays() {
    echo "${GRQ_PUSH_RETRY_DELAYS_OVERRIDE:-1 4 16}"
}

grq_max_push_attempts() {
    echo "${GRQ_PUSH_MAX_ATTEMPTS:-3}"
}

# Run a git command wrapped with the timeout helper (when available).
# Usage: grq_run_git <git args...>
# Caller is responsible for stdout/stderr redirection.
grq_run_git() {
    local timeout_bin
    timeout_bin=$(grq_timeout_cmd)
    local secs
    secs=$(grq_git_timeout_secs)
    if [ -n "$timeout_bin" ]; then
        "$timeout_bin" "$secs" git "$@"
    else
        git "$@"
    fi
}

# Detect a GitHub rate-limit / abuse response in arbitrary stderr text on
# stdin. Returns 0 (true) when it looks like a rate limit, 1 otherwise.
grq_is_rate_limit_error() {
    grep -Eiq "rate limit|x-ratelimit|429|too many requests|abuse detection|secondary rate limit"
}

# Compute how long to sleep when a rate-limit response was detected.
# Echoes a non-negative integer number of seconds.
#
# Resolution order:
#   1. GRQ_RATE_LIMIT_SLEEP_OVERRIDE (used by tests to force a known value).
#   2. `gh api rate_limit` reset epoch minus current time (when `gh` exists).
#   3. Fallback to the supplied backoff seconds (first arg, default 60).
grq_rate_limit_sleep_secs() {
    local fallback="${1:-60}"

    if [ -n "${GRQ_RATE_LIMIT_SLEEP_OVERRIDE:-}" ]; then
        echo "$GRQ_RATE_LIMIT_SLEEP_OVERRIDE"
        return 0
    fi

    if command -v gh >/dev/null 2>&1; then
        local timeout_bin
        timeout_bin=$(grq_timeout_cmd)
        local reset_epoch
        if [ -n "$timeout_bin" ]; then
            reset_epoch=$("$timeout_bin" 10 gh api rate_limit \
                --jq '.resources.core.reset' 2>/dev/null || echo "")
        else
            reset_epoch=$(gh api rate_limit --jq '.resources.core.reset' 2>/dev/null || echo "")
        fi
        if [[ "$reset_epoch" =~ ^[0-9]+$ ]]; then
            local now
            now=$(date +%s)
            local diff=$((reset_epoch - now))
            if [ "$diff" -gt 0 ]; then
                # Add a small jitter so multiple workers don't wake at exactly
                # the same instant.
                echo $((diff + 5))
                return 0
            fi
        fi
    fi

    echo "$fallback"
}

# Discard any local-only commits and working-tree changes on the current
# branch by hard-resetting to origin/<branch> and cleaning untracked files.
# This guards against the next service update committing on top of a stale
# unpushed commit, which would falsely mark the previous service as alive.
#
# Caller must already be in the repo directory.
grq_recover_to_remote() {
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
        echo "Warning: cannot recover detached HEAD to remote" >&2
        return 1
    fi

    local timeout_bin
    timeout_bin=$(grq_timeout_cmd)
    local secs
    secs=$(grq_git_timeout_secs)

    # Fetch latest origin so the reset target reflects the remote tip.
    if [ -n "$timeout_bin" ]; then
        "$timeout_bin" "$secs" git fetch --quiet origin "$branch" 2>/dev/null || true
    else
        git fetch --quiet origin "$branch" 2>/dev/null || true
    fi

    git reset --hard "origin/${branch}" 2>/dev/null || return 1
    git clean -fd 2>/dev/null || true
    return 0
}
