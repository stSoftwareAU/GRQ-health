#!/bin/bash
# Repo Health Tracking Snippet
#
# This file can be used in two ways:
#
#   1. As a sourceable library that exposes report_repo_health().
#      Example:
#           LOG_FILE="$HOME/logs/quality.log"
#           source /path/to/GRQ-health/helpers/repo-health-snippet.sh
#           ./quality.sh >"$LOG_FILE" 2>&1
#           report_repo_health "Quality" "$LOG_FILE" || exit $?
#
#   2. As a copy-paste template. See helpers/REPO_HEALTH_SNIPPET.md for the
#      canonical copy-paste patterns (success-only and success-plus-failure).
#
# IMPORTANT: log contents are committed publicly to the GRQ-health repo.
# Callers MUST redact any secrets before passing a log file to this helper.

# Default location of the GRQ-health checkout relative to the caller's CWD.
# Override either variable from the caller's environment before sourcing or
# before invoking report_repo_health().
: "${GRQ_HEALTH_DIR:=../GRQ-health}"
: "${GRQ_HEALTH_REPO:=git@github.com:stSoftwareAU/GRQ-health.git}"

# Ensure the GRQ-health checkout exists, cloning it if necessary.
_grq_health_ensure_checkout() {
    local dir="$1"
    local repo="$2"
    if [ ! -d "$dir" ]; then
        git clone --depth=1 "$repo" "$dir" >/dev/null 2>&1 || {
            echo "Warning: failed to clone GRQ-health from $repo" >&2
            return 1
        }
    fi
    return 0
}

# report_repo_health <task_name> <log_file>
#
# Call this immediately after the task whose outcome you want to report. The
# function inspects $? (the exit status of the previous command) and invokes
# helpers/repos.sh with the matching success or failure flags:
#
#   - exit 0  -> repos.sh "<task_name>"
#   - exit N  -> repos.sh "<task_name>" --failed --log "<log_file>" --exit-code "N"
#
# The function returns the original exit code so callers can continue to
# propagate it (e.g. `report_repo_health "Quality" "$LOG_FILE" || exit $?`).
#
# Log files passed to this helper are copied into the GRQ-health repo under
# docs/logs/<task-slug>/ and committed publicly. Only the last 5 log files per
# task are retained (retention is handled by repos.sh).
report_repo_health() {
    local exit_code=$?
    local task_name="$1"
    local log_file="$2"

    if [ -z "$task_name" ]; then
        echo "Error: report_repo_health requires a task name." >&2
        return 2
    fi

    local dir="${GRQ_HEALTH_DIR:-../GRQ-health}"
    local repo="${GRQ_HEALTH_REPO:-git@github.com:stSoftwareAU/GRQ-health.git}"

    if ! _grq_health_ensure_checkout "$dir" "$repo"; then
        return "$exit_code"
    fi

    local repos_script="${dir}/helpers/repos.sh"
    if [ ! -x "$repos_script" ]; then
        echo "Warning: ${repos_script} is not executable or missing." >&2
        return "$exit_code"
    fi

    if [ "$exit_code" -eq 0 ]; then
        "$repos_script" "$task_name"
    else
        if [ -z "$log_file" ]; then
            echo "Error: report_repo_health requires a log file path on failure." >&2
            return "$exit_code"
        fi
        if [ ! -f "$log_file" ]; then
            echo "Warning: log file not found at $log_file — skipping failure report." >&2
            return "$exit_code"
        fi
        "$repos_script" "$task_name" --failed --log "$log_file" --exit-code "$exit_code"
    fi

    return "$exit_code"
}

# When the file is executed directly (rather than sourced) print a short
# usage message. The copy-paste templates live in REPO_HEALTH_SNIPPET.md.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    cat <<'USAGE'
repo-health-snippet.sh is a sourceable library, not a runnable script.

Usage:
    $ source /path/to/GRQ-health/helpers/repo-health-snippet.sh

    $ LOG_FILE="$HOME/logs/quality.log"
    $ ./quality.sh >"$LOG_FILE" 2>&1
    $ report_repo_health "Quality" "$LOG_FILE" || exit $?

See helpers/REPO_HEALTH_SNIPPET.md for copy-paste patterns.
USAGE
    exit 0
fi
