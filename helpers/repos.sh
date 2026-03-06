#!/bin/bash
set -euo pipefail

# Script to update repos.json with a repo's last commit timestamp
# Handles git operations including pull, commit, and push with conflict recovery
# 
# Usage:
#   ./helpers/repos.sh <repo_name>
#
# Example:
#   ./helpers/repos.sh "Dividends"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
REPOS_JSON="${PROJECT_ROOT}/docs/repos.json"

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

# Check arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <repo_name>"
    echo "Example: $0 \"Dividends\""
    exit 1
fi

# Support --validate flag for testing validation without side effects
if [ "$1" = "--validate" ]; then
    if [ $# -lt 2 ]; then
        echo "Usage: $0 --validate <repo_name>" >&2
        exit 1
    fi
    validate_repo_name "$2"
    exit $?
fi

REPO_NAME="$1"

# Validate the repo name before proceeding
validate_repo_name "$REPO_NAME" || exit 1

# Get current UTC timestamp (Unix timestamp)
CURRENT_TS=$(date +%s)

# Function to update repos.json
update_repos_json() {
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
    if [ -n "$EXISTING_REPO" ] && [ -n "$LAST_UPDATE_TS" ]; then
        TIME_DIFF=$((CURRENT_TS - LAST_UPDATE_TS))
        if [ "$TIME_DIFF" -lt 3600 ]; then
            # Updated within the last hour, skip update
            MINUTES_AGO=$((TIME_DIFF / 60))
            echo "Skipping update for '${REPO_NAME}' - last updated ${MINUTES_AGO} minutes ago (within 1 hour threshold)"
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
    else
        # Add new repo
        NEW_REPO="{\"name\": \"${REPO_NAME}\", \"last_commit_ts\": ${CURRENT_TS}}"
        
        jq --argjson new_repo "$NEW_REPO" \
           '.repos += [$new_repo]' \
           "$REPOS_JSON" > "${REPOS_JSON}.tmp" && mv "${REPOS_JSON}.tmp" "$REPOS_JSON"
        echo "Added repo '${REPO_NAME}' with timestamp ${CURRENT_TS}"
    fi
}

# Handle git operations: pull first, then update repos.json, then commit/push
# This handles updates from other machines and merge conflicts
# Temporarily disable strict error handling for git operations to allow graceful recovery
set +e
cd "${PROJECT_ROOT}"

# Step 1: Pull latest changes first to handle concurrent updates from other machines
GIT_PULL_SUCCESS=false
if git pull --quiet 2>/dev/null; then
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
        if git pull --quiet 2>/dev/null; then
            GIT_PULL_SUCCESS=true
        fi
    fi
    
    # If still not successful, check for rebase state
    if [ "$GIT_PULL_SUCCESS" = false ]; then
        if [ -d "${PROJECT_ROOT}/.git/rebase-apply" ] || [ -d "${PROJECT_ROOT}/.git/rebase-merge" ]; then
            git rebase --abort 2>/dev/null
            if git pull --quiet 2>/dev/null; then
                GIT_PULL_SUCCESS=true
            fi
        fi
    fi
    
    if [ "$GIT_PULL_SUCCESS" = false ]; then
        echo "Warning: Could not resolve git state, will attempt to update repos.json anyway"
    fi
fi

# Step 2: Now update repos.json with our timestamp (works with pulled version)
update_repos_json

# Step 3: Stage, commit, and push
if git add "${REPOS_JSON}" 2>/dev/null; then
    # Check if there are changes to commit
    if ! git diff --cached --quiet 2>/dev/null; then
        # Commit the changes
        if git commit -m "Update repo health: ${REPO_NAME}" --quiet 2>/dev/null; then
            # Push the changes with retries (handles transient network/auth failures)
            GIT_PUSH_MAX_ATTEMPTS=3
            GIT_PUSH_RETRY_DELAY=5
            GIT_PUSH_SUCCESS=false
            for attempt in $(seq 1 "$GIT_PUSH_MAX_ATTEMPTS"); do
                if git push --quiet 2>/dev/null; then
                    GIT_PUSH_SUCCESS=true
                    break
                fi
                if [ "$attempt" -lt "$GIT_PUSH_MAX_ATTEMPTS" ]; then
                    echo "Warning: git push failed (attempt ${attempt}/${GIT_PUSH_MAX_ATTEMPTS}), retrying in ${GIT_PUSH_RETRY_DELAY}s..."
                    sleep "$GIT_PUSH_RETRY_DELAY"
                fi
            done
            if [ "$GIT_PUSH_SUCCESS" = false ]; then
                echo "Warning: git push failed after ${GIT_PUSH_MAX_ATTEMPTS} attempts, but local changes are committed"
            fi
        else
            echo "Warning: git commit failed (may be no changes or commit error)"
        fi
    fi
fi

cd - > /dev/null
# Re-enable strict error handling
set -euo pipefail

