#!/bin/bash
set -euo pipefail

# Script to update repos.json with a repo's last commit timestamp
# Handles git operations including pull, commit, and push with conflict recovery
#
# Usage:
#   ./helpers/repos.sh <repo_name>                                    # record success
#   ./helpers/repos.sh <repo_name> --failed --log /path/to/run.log    # record failure with log file
#   ./helpers/repos.sh <repo_name> --failed --log - < run.log         # record failure with log from stdin
#
# Optional failure flags:
#   --exit-code <N>     Record the non-zero exit status
#   --message <text>    Record a one-line summary
#
# Testing flags:
#   --validate <name>   Validate repo name without side effects
#   --dry-run           Skip git operations (for testing)
#   --project-root <p>  Override project root directory (for testing)
#   --skip-rate-limit   Skip the 1-hour rate limit check (for testing)
#
# Example:
#   ./helpers/repos.sh "Dividends"
#   ./helpers/repos.sh "Quality" --failed --log /tmp/run.log --exit-code 1 --message "lint errors"
#
# Status signalling (Issue #122):
#   On every exit, a one-line machine-readable status is written to stderr:
#     repos.sh status=<status> reason=<reason> name='<repo_name>'
#   Statuses: skipped | updated | added | failed-recorded | failed | unknown
#   Reasons : rate-limited | success | failure-recorded | push-failed |
#             validation-failed | git-state-unresolved | unknown
#   git-state-unresolved (GRQ#4237): the pre-commit pull could not be resolved,
#   so the check-in aborted rather than committing from an unknown state.
#   Callers that suppress stdout (e.g. runWithTimeout(..., { quiet: true }))
#   can capture stderr to distinguish pushed/skipped/failed outcomes
#   without parsing localised user-facing messages.

# Maximum number of log files to retain per task
LOG_RETENTION_COUNT=5

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Issue #122: emit a machine-readable status line to stderr on exit.
# Callers that suppress stdout (e.g. the Deno worker's
# runWithTimeout(..., { quiet: true })) can capture stderr to distinguish
# pushed / skipped / failed outcomes without parsing localised messages.
# Format:
#   repos.sh status=<status> reason=<reason> name='<repo_name>'
# Statuses: skipped | updated | added | failed-recorded | failed |
#           update-dropped | unknown
# update-dropped (Issue #139): non-fatal — the health update could not be
# re-applied after a persistent rebase conflict on the shared docs/repos.json,
# so it was dropped. Surfaced distinctly instead of masked as success.
RUN_STATUS="unknown"
RUN_REASON="unknown"
REPO_NAME=""

emit_status_on_exit() {
    local rc=$?
    # Do not emit if status was never set (e.g. usage banner before parsing).
    echo "repos.sh status=${RUN_STATUS} reason=${RUN_REASON} name='${REPO_NAME}'" >&2
    return "$rc"
}
trap emit_status_on_exit EXIT

# Source shared git retry helpers (Issue #117).
# shellcheck source=./git-retry.sh
if [ -f "${SCRIPT_DIR}/git-retry.sh" ]; then
    # shellcheck disable=SC1091
    . "${SCRIPT_DIR}/git-retry.sh"
fi

# Validate repo name: alphanumeric, hyphens, underscores, periods, colons, forward slashes, spaces
validate_repo_name() {
    local name="$1"
    if [ -z "$name" ]; then
        echo "Error: Repo name cannot be empty." >&2
        return 1
    fi
    if ! [[ "$name" =~ ^[a-zA-Z0-9' '_./+:=-]+$ ]]; then
        echo "Error: Invalid repo name '$name'. Only alphanumeric, spaces, hyphens, underscores, periods, colons, forward slashes, and plus signs allowed." >&2
        return 1
    fi
    return 0
}

# Sanitise task name into a safe directory slug
# Replaces any character that is not alphanumeric, hyphen, or underscore with a hyphen
sanitise_task_slug() {
    local name="$1"
    echo "$name" | sed 's/[^a-zA-Z0-9_-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

# Validate a log file path for security
# Rejects: path traversal, symlinks outside project, non-existent files, device files
validate_log_path() {
    local log_path="$1"

    # stdin is always valid
    if [ "$log_path" = "-" ]; then
        return 0
    fi

    # Reject paths containing ..
    if [[ "$log_path" == *".."* ]]; then
        echo "Error: Log path must not contain '..' (path traversal)." >&2
        return 1
    fi

    # Resolve the real path to check location
    local resolved
    resolved=$(readlink -f "$log_path" 2>/dev/null || python3 -c "import os; print(os.path.realpath('$log_path'))" 2>/dev/null || echo "")

    # For absolute paths, only allow files under temp directories or the project root
    if [[ "$log_path" == /* ]]; then
        if [ ! -f "$log_path" ]; then
            echo "Error: Log file does not exist: $log_path" >&2
            return 1
        fi
        # Resolve and check the file is under an allowed directory
        if [ -z "$resolved" ]; then
            echo "Error: Cannot resolve log path: $log_path" >&2
            return 1
        fi
        # Allowed directories: temp dirs (various OS patterns), project root
        local allowed=false
        case "$resolved" in
            /tmp/*|/private/tmp/*|/var/tmp/*|/private/var/folders/*)
                allowed=true ;;
        esac
        # Also check TMPDIR if set
        if [ "$allowed" = false ] && [ -n "${TMPDIR:-}" ]; then
            local resolved_tmpdir
            resolved_tmpdir=$(readlink -f "${TMPDIR}" 2>/dev/null || python3 -c "import os; print(os.path.realpath('${TMPDIR}'))" 2>/dev/null || echo "")
            if [ -n "$resolved_tmpdir" ] && [[ "$resolved" == "${resolved_tmpdir}"/* ]]; then
                allowed=true
            fi
        fi
        # Check project root
        local resolved_project
        resolved_project=$(readlink -f "$PROJECT_ROOT" 2>/dev/null || python3 -c "import os; print(os.path.realpath('$PROJECT_ROOT'))" 2>/dev/null || echo "$PROJECT_ROOT")
        if [[ "$resolved" == "${resolved_project}"/* ]]; then
            allowed=true
        fi
        if [ "$allowed" = false ]; then
            echo "Error: Log path is outside allowed directories (project root or temp): $log_path" >&2
            return 1
        fi
        return 0
    fi

    # Relative path — check existence
    if [ ! -f "$log_path" ]; then
        echo "Error: Log file does not exist: $log_path" >&2
        return 1
    fi

    return 0
}

# Check arguments
if [ $# -lt 1 ]; then
    RUN_STATUS="failed"
    RUN_REASON="validation-failed"
    echo "Usage: $0 <repo_name>"
    echo "       $0 <repo_name> --failed --log <path>"
    echo "Example: $0 \"Dividends\""
    exit 1
fi

# Support --validate flag for testing validation without side effects
if [ "$1" = "--validate" ]; then
    if [ $# -lt 2 ]; then
        RUN_STATUS="failed"
        RUN_REASON="validation-failed"
        echo "Usage: $0 --validate <repo_name>" >&2
        exit 1
    fi
    REPO_NAME="$2"
    if validate_repo_name "$2"; then
        RUN_STATUS="updated"
        RUN_REASON="success"
        exit 0
    else
        RUN_STATUS="failed"
        RUN_REASON="validation-failed"
        exit 1
    fi
fi

# Parse arguments
DRY_RUN=false
SKIP_RATE_LIMIT=false
FAILED_MODE=false
LOG_PATH=""
FAILURE_EXIT_CODE=""
FAILURE_MESSAGE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --project-root)
            PROJECT_ROOT="$2"
            shift 2
            ;;
        --skip-rate-limit)
            SKIP_RATE_LIMIT=true
            shift
            ;;
        --failed)
            FAILED_MODE=true
            shift
            ;;
        --log)
            LOG_PATH="$2"
            shift 2
            ;;
        --exit-code)
            FAILURE_EXIT_CODE="$2"
            shift 2
            ;;
        --message)
            FAILURE_MESSAGE="$2"
            shift 2
            ;;
        *)
            if [ -z "$REPO_NAME" ]; then
                REPO_NAME="$1"
            fi
            shift
            ;;
    esac
done

REPOS_JSON="${PROJECT_ROOT}/docs/repos.json"

# Validate the repo name before proceeding
if [ -z "$REPO_NAME" ]; then
    RUN_STATUS="failed"
    RUN_REASON="validation-failed"
    echo "Error: Repo name is required." >&2
    exit 1
fi
if ! validate_repo_name "$REPO_NAME"; then
    RUN_STATUS="failed"
    RUN_REASON="validation-failed"
    exit 1
fi

# In failed mode, --log is required
if [ "$FAILED_MODE" = true ] && [ -z "$LOG_PATH" ]; then
    RUN_STATUS="failed"
    RUN_REASON="validation-failed"
    echo "Error: --log is required when using --failed." >&2
    exit 1
fi

# Validate the log path if provided
if [ -n "$LOG_PATH" ]; then
    if ! validate_log_path "$LOG_PATH"; then
        RUN_STATUS="failed"
        RUN_REASON="validation-failed"
        exit 1
    fi
fi

# Get current UTC timestamp (Unix timestamp)
CURRENT_TS=$(date +%s)

# Function to store the failure log file and enforce retention
store_failure_log() {
    local task_slug
    task_slug=$(sanitise_task_slug "$REPO_NAME")
    local log_dir="${PROJECT_ROOT}/docs/logs/${task_slug}"
    mkdir -p "$log_dir"

    # Generate timestamped filename with unique suffix to avoid collisions
    local log_ts
    log_ts=$(date -u +"%Y%m%d-%H%M%S")
    local log_filename="${log_ts}.log"
    # If file already exists, append a numeric suffix
    local suffix=1
    while [ -f "${log_dir}/${log_filename}" ]; do
        log_filename="${log_ts}-${suffix}.log"
        suffix=$((suffix + 1))
    done
    local log_dest="${log_dir}/${log_filename}"

    # Copy log content
    if [ "$LOG_PATH" = "-" ]; then
        cat > "$log_dest"
    else
        cp "$LOG_PATH" "$log_dest"
    fi

    # Enforce retention: keep only the last LOG_RETENTION_COUNT files
    local file_count
    file_count=$(find "$log_dir" -maxdepth 1 -name "*.log" -type f | wc -l | tr -d ' ')
    if [ "$file_count" -gt "$LOG_RETENTION_COUNT" ]; then
        # Delete oldest files (sorted by name which is timestamp-based)
        local files_to_delete
        files_to_delete=$(find "$log_dir" -maxdepth 1 -name "*.log" -type f | sort | head -n "$((file_count - LOG_RETENTION_COUNT))")
        echo "$files_to_delete" | while IFS= read -r old_file; do
            if [ -n "$old_file" ] && [ -f "$old_file" ]; then
                rm -f "$old_file"
            fi
        done
    fi

    # Return the repo-relative path (relative to docs/)
    echo "logs/${task_slug}/${log_filename}"
}

# Function to update repos.json for a successful run
update_repos_json_success() {
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is required but not found. Please install jq."
        exit 1
    fi

    # Ensure repos.json exists with proper structure
    if [ ! -f "$REPOS_JSON" ]; then
        echo "{\"repos\": []}" > "$REPOS_JSON"
    fi

    # Read current repos array
    REPOS=$(jq -c '.repos // []' "$REPOS_JSON")

    # Check if repo already exists and get its last commit timestamp
    EXISTING_REPO=$(echo "$REPOS" | jq -r ".[] | select(.name == \"${REPO_NAME}\") | .name // empty")
    LAST_UPDATE_TS=$(echo "$REPOS" | jq -r ".[] | select(.name == \"${REPO_NAME}\") | .last_commit_ts // empty")

    # If repo exists, check if it was updated within the last hour (3600 seconds)
    if [ "$SKIP_RATE_LIMIT" = false ] && [ -n "$EXISTING_REPO" ] && [ -n "$LAST_UPDATE_TS" ]; then
        TIME_DIFF=$((CURRENT_TS - LAST_UPDATE_TS))
        if [ "$TIME_DIFF" -lt 3600 ]; then
            # Updated within the last hour, skip update
            MINUTES_AGO=$((TIME_DIFF / 60))
            echo "Skipping update for '${REPO_NAME}' - last updated ${MINUTES_AGO} minutes ago (within 1 hour threshold)"
            RUN_STATUS="skipped"
            RUN_REASON="rate-limited"
            return 0
        fi
    fi

    # Proceed with update (either new repo or last update was more than 1 hour ago)
    if [ -n "$EXISTING_REPO" ]; then
        # Update existing repo
        jq --arg name "$REPO_NAME" \
           --arg ts "$CURRENT_TS" \
           '.repos |= map(if .name == $name then .last_commit_ts = ($ts | tonumber) else . end)' \
           "$REPOS_JSON" > "${REPOS_JSON}.tmp" && mv "${REPOS_JSON}.tmp" "$REPOS_JSON"
        echo "Updated repo '${REPO_NAME}' with timestamp ${CURRENT_TS}"
        RUN_STATUS="updated"
        RUN_REASON="success"
    else
        # Add new repo
        NEW_REPO="{\"name\": \"${REPO_NAME}\", \"last_commit_ts\": ${CURRENT_TS}}"

        jq --argjson new_repo "$NEW_REPO" \
           '.repos += [$new_repo]' \
           "$REPOS_JSON" > "${REPOS_JSON}.tmp" && mv "${REPOS_JSON}.tmp" "$REPOS_JSON"
        echo "Added repo '${REPO_NAME}' with timestamp ${CURRENT_TS}"
        RUN_STATUS="added"
        RUN_REASON="success"
    fi
}

# Function to update repos.json for a failed run
update_repos_json_failure() {
    local log_relative_path="$1"

    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is required but not found. Please install jq."
        exit 1
    fi

    # Ensure repos.json exists with proper structure
    if [ ! -f "$REPOS_JSON" ]; then
        echo "{\"repos\": []}" > "$REPOS_JSON"
    fi

    # Read current repos array
    REPOS=$(jq -c '.repos // []' "$REPOS_JSON")

    # Check if repo already exists
    EXISTING_REPO=$(echo "$REPOS" | jq -r ".[] | select(.name == \"${REPO_NAME}\") | .name // empty")

    if [ -n "$EXISTING_REPO" ]; then
        # Update existing repo with failure fields (do NOT touch last_commit_ts)
        local jq_filter
        jq_filter='.repos |= map(if .name == $name then .last_failure_ts = ($ts | tonumber) | .last_failure_log = $log'

        local jq_args=()
        jq_args+=(--arg name "$REPO_NAME")
        jq_args+=(--arg ts "$CURRENT_TS")
        jq_args+=(--arg log "$log_relative_path")

        if [ -n "$FAILURE_EXIT_CODE" ]; then
            jq_filter="$jq_filter"' | .last_failure_exit_code = ($exit_code | tonumber)'
            jq_args+=(--arg exit_code "$FAILURE_EXIT_CODE")
        fi

        if [ -n "$FAILURE_MESSAGE" ]; then
            jq_filter="$jq_filter"' | .last_failure_message = $message'
            jq_args+=(--arg message "$FAILURE_MESSAGE")
        fi

        jq_filter="$jq_filter"' else . end)'

        jq "${jq_args[@]}" "$jq_filter" "$REPOS_JSON" > "${REPOS_JSON}.tmp" && mv "${REPOS_JSON}.tmp" "$REPOS_JSON"
        echo "Updated repo '${REPO_NAME}' with failure at timestamp ${CURRENT_TS}"
    else
        # Add new repo entry with failure fields (no last_commit_ts since it never succeeded)
        local new_entry
        new_entry=$(jq -n --arg name "$REPO_NAME" --arg ts "$CURRENT_TS" --arg log "$log_relative_path" \
            '{name: $name, last_commit_ts: 0, last_failure_ts: ($ts | tonumber), last_failure_log: $log}')

        if [ -n "$FAILURE_EXIT_CODE" ]; then
            new_entry=$(echo "$new_entry" | jq --arg ec "$FAILURE_EXIT_CODE" '. + {last_failure_exit_code: ($ec | tonumber)}')
        fi
        if [ -n "$FAILURE_MESSAGE" ]; then
            new_entry=$(echo "$new_entry" | jq --arg msg "$FAILURE_MESSAGE" '. + {last_failure_message: $msg}')
        fi

        jq --argjson new_repo "$new_entry" '.repos += [$new_repo]' \
            "$REPOS_JSON" > "${REPOS_JSON}.tmp" && mv "${REPOS_JSON}.tmp" "$REPOS_JSON"
        echo "Added repo '${REPO_NAME}' with failure at timestamp ${CURRENT_TS}"
    fi
}

# Main logic: decide between success and failure modes
if [ "$FAILED_MODE" = true ]; then
    # Store the log file first
    LOG_RELATIVE_PATH=$(store_failure_log)

    # Update repos.json with failure info
    update_repos_json_failure "$LOG_RELATIVE_PATH"

    # Status: a failure was recorded successfully (--failed mode is a
    # successful invocation of repos.sh recording an upstream failure).
    RUN_STATUS="failed-recorded"
    RUN_REASON="failure-recorded"

    # Commit message for failures
    COMMIT_MSG="Update repo health (failure): ${REPO_NAME}"
else
    # Success mode (original behaviour)
    update_repos_json_success

    # Commit message for successes
    COMMIT_MSG="Update repo health: ${REPO_NAME}"
fi

# Skip git operations in dry-run mode
if [ "$DRY_RUN" = true ]; then
    exit 0
fi

# Handle git operations: pull first, then update repos.json, then commit/push
# Temporarily disable strict error handling for git operations to allow graceful recovery
set +e
cd "${PROJECT_ROOT}"

# Step 1: Pull latest changes first to handle concurrent updates from other machines
#
# GRQ#4237: pull with --rebase --autostash. docs/repos.json was rewritten a few
# lines above, so this pull always runs against a DIRTY tree: a plain `git pull`
# refuses with "Your local changes … would be overwritten by merge" and, once a
# peer host has pushed, adds "Need to specify how to reconcile divergent
# branches". Both landed on the "could not resolve git state" path below, which
# used to commit and push from that unresolved state anyway.
GIT_PULL_SUCCESS=false
PULL_HEAD_BEFORE=$(git rev-parse HEAD 2>/dev/null || echo "")
PULL_STDERR_FILE=$(mktemp 2>/dev/null || echo "/tmp/repos_pull_stderr.$$")
if grq_run_git pull --rebase --autostash --quiet 2>"$PULL_STDERR_FILE"; then
    GIT_PULL_SUCCESS=true
else
    # If pull fails, try to recover from merge conflicts
    echo "Warning: git pull failed, attempting to recover..."

    # Check if we're in a merge state
    if [ -f "${PROJECT_ROOT}/.git/MERGE_HEAD" ]; then
        # Check if repos.json is conflicted
        if git diff --name-only --diff-filter=U 2>/dev/null | grep -q "^docs/repos.json$"; then
            # For repos.json conflicts, take remote version (we'll update it next)
            git checkout --theirs "${REPOS_JSON}" 2>/dev/null
            git add "${REPOS_JSON}" 2>/dev/null
            git commit --no-edit --quiet 2>/dev/null || git merge --abort 2>/dev/null
        else
            # Abort merge for other conflicts
            git merge --abort 2>/dev/null
        fi
        # Try pull again
        if grq_run_git pull --rebase --autostash --quiet 2>"$PULL_STDERR_FILE"; then
            GIT_PULL_SUCCESS=true
        fi
    fi

    # If still not successful, check for rebase state
    if [ "$GIT_PULL_SUCCESS" = false ]; then
        if [ -d "${PROJECT_ROOT}/.git/rebase-apply" ] || [ -d "${PROJECT_ROOT}/.git/rebase-merge" ]; then
            git rebase --abort 2>/dev/null
            if grq_run_git pull --rebase --autostash --quiet 2>"$PULL_STDERR_FILE"; then
                GIT_PULL_SUCCESS=true
            fi
        fi
    fi

    if [ "$GIT_PULL_SUCCESS" = false ]; then
        # GRQ#4237: never carry on from a state we have not resolved.
        #
        # A CONFLICT is the routine concurrent-writer case on the shared
        # docs/repos.json: clear the half-finished rebase/merge so the tree is
        # consistent again and let the push loop's rebase → reset → re-apply
        # recovery (Issue #139) publish the update or report update-dropped.
        # Anything else — an unreachable remote, a corrupt clone — is a genuine
        # fault: abort loudly rather than committing and pushing blind.
        if [ -d "${PROJECT_ROOT}/.git/rebase-apply" ] || \
           [ -d "${PROJECT_ROOT}/.git/rebase-merge" ] || \
           [ -f "${PROJECT_ROOT}/.git/MERGE_HEAD" ] || \
           [ -n "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]; then
            git rebase --abort 2>/dev/null
            git merge --abort 2>/dev/null
            rm -rf "${PROJECT_ROOT}/.git/rebase-apply" "${PROJECT_ROOT}/.git/rebase-merge" 2>/dev/null
            echo "Warning: pre-commit pull conflicted on the shared health files; rebase aborted, resolving during push"
        fi

        # Re-check: a state we could not make consistent must stop the check-in.
        if [ "$GIT_PULL_SUCCESS" = false ] && { \
             [ -d "${PROJECT_ROOT}/.git/rebase-apply" ] || \
             [ -d "${PROJECT_ROOT}/.git/rebase-merge" ] || \
             [ -f "${PROJECT_ROOT}/.git/MERGE_HEAD" ] || \
             [ -n "$(git diff --name-only --diff-filter=U 2>/dev/null)" ] || \
             ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1 || \
             ! grq_run_git ls-remote --exit-code origin >/dev/null 2>&1; }; then
            echo "ERROR: could not resolve git state in ${PROJECT_ROOT}; aborting the health check-in" >&2
            if [ -s "$PULL_STDERR_FILE" ]; then
                echo "Last git pull stderr:" >&2
                sed 's/^/  /' "$PULL_STDERR_FILE" >&2
            fi
            echo "Branch status (git status --porcelain=v2 --branch):" >&2
            git status --porcelain=v2 --branch 2>&1 | sed 's/^/  /' >&2 || true
            rm -f "$PULL_STDERR_FILE" 2>/dev/null
            # Leave the clone as we found it: the uncommitted repos.json edit
            # (and any failure log written for it) is regenerated next run.
            if grq_recover_to_remote 2>/dev/null; then
                echo "Info: reset local clone to the remote and cleaned working tree"
            else
                echo "Warning: failed to reset local clone to the remote" >&2
            fi
            RUN_STATUS="failed"
            RUN_REASON="git-state-unresolved"
            cd - > /dev/null 2>&1 || true
            set -euo pipefail
            exit 1
        fi
    fi
fi

PULL_HEAD_AFTER=$(git rev-parse HEAD 2>/dev/null || echo "")
if [ "$GIT_PULL_SUCCESS" = true ] && [ -n "$PULL_HEAD_BEFORE" ] && \
   [ "$PULL_HEAD_BEFORE" != "$PULL_HEAD_AFTER" ]; then
    echo "Info: pre-commit pull rebased onto the remote (${PULL_HEAD_BEFORE:0:7} -> ${PULL_HEAD_AFTER:0:7})"
fi
rm -f "$PULL_STDERR_FILE" 2>/dev/null

# Step 2: Stage all changed files (repos.json and any log files)
FILES_TO_ADD=("${REPOS_JSON}")
if [ "$FAILED_MODE" = true ]; then
    # Also stage the logs directory
    TASK_SLUG=$(sanitise_task_slug "$REPO_NAME")
    LOG_DIR="${PROJECT_ROOT}/docs/logs/${TASK_SLUG}"
    if [ -d "$LOG_DIR" ]; then
        FILES_TO_ADD+=("$LOG_DIR")
    fi
fi

STAGED_SOMETHING=false
for f in "${FILES_TO_ADD[@]}"; do
    if git add "$f" 2>/dev/null; then
        STAGED_SOMETHING=true
    fi
done

# Re-apply this host's health update onto the current working tree and commit
# it (Issue #139 defect 2). Used by the push loop after a rebase conflict on
# the shared docs/repos.json forces a hard reset to the remote tip: rather
# than discarding this host's update (and silently reporting success), we
# regenerate the entry on top of the fresh base and re-commit it so it can be
# pushed. The update_repos_json_* helpers are idempotent and keyed on the host
# name, so re-running them on the fresh base cannot itself conflict.
# Returns:
#   0 — re-applied and committed a fresh local commit ready to push
#   2 — nothing to commit (remote already carries this host's update)
#   1 — could not re-apply (e.g. failure-mode log no longer on disk)
reapply_health_update() {
    if [ "$FAILED_MODE" = true ]; then
        # The failure log written earlier was removed by the hard reset. Only
        # re-create it when the source log is still a readable file; a consumed
        # stdin log ("-") cannot be reproduced, so surface a dropped update.
        if [ "$LOG_PATH" != "-" ] && [ -f "$LOG_PATH" ]; then
            LOG_RELATIVE_PATH=$(store_failure_log)
            FILES_TO_ADD=("${REPOS_JSON}")
            local reapply_slug reapply_log_dir
            reapply_slug=$(sanitise_task_slug "$REPO_NAME")
            reapply_log_dir="${PROJECT_ROOT}/docs/logs/${reapply_slug}"
            if [ -d "$reapply_log_dir" ]; then
                FILES_TO_ADD+=("$reapply_log_dir")
            fi
            update_repos_json_failure "$LOG_RELATIVE_PATH"
        else
            return 1
        fi
    else
        update_repos_json_success
    fi

    local reapply_staged=false reapply_file
    for reapply_file in "${FILES_TO_ADD[@]}"; do
        if git add "$reapply_file" 2>/dev/null; then
            reapply_staged=true
        fi
    done

    if [ "$reapply_staged" = true ] && ! git diff --cached --quiet 2>/dev/null; then
        if git commit -m "$COMMIT_MSG" --quiet 2>/dev/null; then
            return 0
        fi
        return 1
    fi
    return 2
}

# Step 3: Commit and push
# Issue #117 + #1862 + #139: Push retries use exponential backoff (default
# 1s, 4s, 16s, 30s, 60s, jittered) and wrap each git call in a 120s timeout to
# handle slow networks. We push optimistically on the first attempt (the base
# was just freshened by the Step 1 pull); every subsequent retry fetches and
# rebases BEFORE pushing so even the final attempt lands on the latest remote
# tip instead of re-sending a now-stale commit (#139 defect 1). If a rebase
# conflicts on repos.json we reset to the remote and re-apply this host's
# update on top, then keep retrying — the update is preserved rather than
# silently dropped (#139 defect 2). A GitHub rate-limit response (HTTP 429 /
# abuse detection / "rate limit" in stderr) triggers a sleep until the reset
# window (probed via `gh api rate_limit` when available) before the next
# attempt. When all retries are exhausted we reset the local clone to
# origin/<branch> + clean -fd so the next service update does not commit on top
# of a stale unpushed commit (which would falsely mark the previous service as
# alive), surface the actual stderr, and exit non-zero so the failure itself is
# observable. If an update genuinely cannot be re-applied it is surfaced as a
# non-fatal status=update-dropped rather than masked as success.
PUSH_FINAL_STATUS=0
UPDATE_DROPPED=false
if [ "$STAGED_SOMETHING" = true ]; then
    if ! git diff --cached --quiet 2>/dev/null; then
        # Commit the changes
        if git commit -m "$COMMIT_MSG" --quiet 2>/dev/null; then
            # Backoff defaults from git-retry.sh; legacy
            # GIT_PUSH_RETRY_DELAY_OVERRIDE still honoured (back-compat).
            # Issue #125: defaults bumped to "1 4 16 30 60" / 5 attempts so
            # 12+ concurrent Vibe Coder writers racing on docs/repos.json
            # can clear within the retry budget instead of falling through
            # to the recover-to-remote path and discarding the local commit.
            BACKOFF_DELAYS_RAW=$(grq_backoff_delays 2>/dev/null || echo "1 4 16 30 60")
            # shellcheck disable=SC2206
            BACKOFF_DELAYS=( $BACKOFF_DELAYS_RAW )
            GIT_PUSH_MAX_ATTEMPTS=$(grq_max_push_attempts 2>/dev/null || echo 5)
            LEGACY_DELAY="${GIT_PUSH_RETRY_DELAY_OVERRIDE:-}"
            GIT_PUSH_SUCCESS=false
            LAST_PUSH_STDERR=""
            PUSH_STDERR_FILE=$(mktemp 2>/dev/null || echo "/tmp/repos_push_stderr.$$")

            CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

            for attempt in $(seq 1 "$GIT_PUSH_MAX_ATTEMPTS"); do
                # Issue #139 defect 1: rebase BEFORE pushing on every retry
                # (rebase-before-push, not push-then-rebase) so even the final
                # attempt lands on the freshest remote tip. The first attempt
                # pushes optimistically — the Step 1 pull already freshened the
                # base, so the common uncontended path stays a single push.
                # Skip when not on a named branch (nothing to rebase onto in a
                # detached HEAD).
                if [ "$attempt" -gt 1 ] && [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "HEAD" ]; then
                    if grq_run_git fetch --quiet origin "$CURRENT_BRANCH" 2>/dev/null; then
                        if grq_run_git rebase --autostash "origin/${CURRENT_BRANCH}" 2>/dev/null; then
                            echo "Info: rebased onto origin/${CURRENT_BRANCH} before push (attempt ${attempt}/${GIT_PUSH_MAX_ATTEMPTS})"
                        else
                            # Rebase conflict — almost always on the shared
                            # repos.json. Issue #139 defect 2: instead of
                            # discarding this host's update and (silently)
                            # reporting success, reset to the fresh remote tip
                            # and RE-APPLY the update on top, then keep retrying
                            # the push so the update is preserved.
                            echo "Warning: rebase onto origin/${CURRENT_BRANCH} conflicted; resetting to remote and re-applying this host's update"
                            git rebase --abort 2>/dev/null || true
                            rm -rf .git/rebase-merge .git/rebase-apply 2>/dev/null || true
                            git reset --hard "origin/${CURRENT_BRANCH}" 2>/dev/null || true

                            reapply_health_update
                            REAPPLY_RC=$?
                            if [ "$REAPPLY_RC" -eq 0 ]; then
                                echo "Info: re-applied this host's update onto origin/${CURRENT_BRANCH} after conflict"
                            elif [ "$REAPPLY_RC" -eq 2 ]; then
                                # Remote already carries this host's update —
                                # nothing left to push. Treat as success.
                                echo "Info: origin/${CURRENT_BRANCH} already carries this host's update; nothing to push"
                                GIT_PUSH_SUCCESS=true
                                break
                            else
                                # Could not re-apply (e.g. failure-mode log no
                                # longer on disk). Surface a distinct non-fatal
                                # status so the dropped update is observable
                                # instead of masked as success.
                                echo "Warning: could not re-apply this host's update after conflict; update dropped"
                                UPDATE_DROPPED=true
                                break
                            fi
                        fi
                    else
                        echo "Warning: git fetch origin ${CURRENT_BRANCH} failed; pushing without a fresh base (attempt ${attempt}/${GIT_PUSH_MAX_ATTEMPTS})"
                    fi
                fi

                : > "$PUSH_STDERR_FILE"
                if grq_run_git push --quiet 2>"$PUSH_STDERR_FILE"; then
                    GIT_PUSH_SUCCESS=true
                    break
                fi
                LAST_PUSH_STDERR=$(cat "$PUSH_STDERR_FILE" 2>/dev/null || echo "")
                echo "Warning: git push failed (attempt ${attempt}/${GIT_PUSH_MAX_ATTEMPTS}): ${LAST_PUSH_STDERR}"

                # No further attempts remain — stop. The freshest rebase+push
                # already happened on this final attempt (defect 1 fix).
                if [ "$attempt" -ge "$GIT_PUSH_MAX_ATTEMPTS" ]; then
                    break
                fi

                # Decide the inter-attempt sleep. A rate-limit response
                # overrides the standard (jittered) backoff.
                IDX=$((attempt - 1))
                # bash 3.2 (macOS default) errors on ${arr[-1]} with `set -u`,
                # so compute the last index explicitly. The fallback covers
                # the case where attempts > backoff entries (e.g. when a test
                # override supplies fewer delays than the default 5 attempts).
                LAST_IDX=$(( ${#BACKOFF_DELAYS[@]} - 1 ))
                BACKOFF_SECS="${BACKOFF_DELAYS[$IDX]:-${BACKOFF_DELAYS[$LAST_IDX]}}"
                if [ -n "$LEGACY_DELAY" ]; then
                    BACKOFF_SECS="$LEGACY_DELAY"
                fi
                # Issue #139: jitter the backoff so a fleet that collided at the
                # same instant does not retry in lock-step.
                SLEEP_SECS=$(grq_apply_jitter "$BACKOFF_SECS")

                if echo "$LAST_PUSH_STDERR" | grq_is_rate_limit_error; then
                    SLEEP_SECS=$(grq_rate_limit_sleep_secs "$BACKOFF_SECS")
                    echo "Warning: GitHub rate limit detected (attempt ${attempt}/${GIT_PUSH_MAX_ATTEMPTS}); sleeping ${SLEEP_SECS}s before retry"
                fi

                sleep "$SLEEP_SECS"
            done

            if [ "$GIT_PUSH_SUCCESS" = false ] && [ "$UPDATE_DROPPED" = false ]; then
                echo "ERROR: git push failed after ${GIT_PUSH_MAX_ATTEMPTS} attempts"
                if [ -n "$LAST_PUSH_STDERR" ]; then
                    echo "Last git push stderr:"
                    echo "$LAST_PUSH_STDERR" | sed 's/^/  /'
                fi
                echo "Branch status (git status --porcelain=v2 --branch):"
                git status --porcelain=v2 --branch 2>&1 | sed 's/^/  /' || true

                # Discard the stale local commit so the next service update
                # does not commit on top of it (which would falsely mark
                # the previous service as alive).
                if grq_recover_to_remote 2>/dev/null; then
                    echo "Info: reset local clone to origin/${CURRENT_BRANCH} and cleaned working tree"
                else
                    echo "Warning: failed to reset local clone to origin/${CURRENT_BRANCH}"
                fi
                PUSH_FINAL_STATUS=1
            elif [ "$UPDATE_DROPPED" = true ]; then
                # Issue #139 defect 2: the update could not be re-applied after
                # a persistent rebase conflict. This is non-fatal (core work
                # continues) but must be observable, not masked as success.
                # Reset to remote so the next run starts clean; the distinct
                # status=update-dropped is emitted at exit.
                echo "Warning: this host's health update was dropped after a rebase conflict on docs/repos.json"
                if grq_recover_to_remote 2>/dev/null; then
                    echo "Info: reset local clone to origin/${CURRENT_BRANCH} and cleaned working tree"
                else
                    echo "Warning: failed to reset local clone to origin/${CURRENT_BRANCH}"
                fi
            fi

            rm -f "$PUSH_STDERR_FILE" 2>/dev/null || true
        else
            echo "Warning: git commit failed (may be no changes or commit error)"
        fi
    fi
fi

cd - > /dev/null
# Re-enable strict error handling
set -euo pipefail

# Surface push failure as a non-zero exit so the worker can observe it.
if [ "$PUSH_FINAL_STATUS" -ne 0 ]; then
    RUN_STATUS="failed"
    RUN_REASON="push-failed"
    exit "$PUSH_FINAL_STATUS"
fi

# Issue #139 defect 2: a dropped update is non-fatal (exit 0) but must be
# observable rather than masquerading as a normal update.
if [ "${UPDATE_DROPPED:-false}" = true ]; then
    RUN_STATUS="update-dropped"
    RUN_REASON="update-dropped"
fi
