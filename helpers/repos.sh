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

# Check arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <repo_name>"
    echo "Example: $0 \"Dividends\""
    exit 1
fi

REPO_NAME="$1"

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
    
    # Check if repo already exists
    EXISTING_REPO=$(echo "$REPOS" | jq -r ".[] | select(.name == \"${REPO_NAME}\") | .name // empty")
    
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
            # Push the changes
            if ! git push --quiet 2>/dev/null; then
                echo "Warning: git push failed, but local changes are committed"
            fi
        else
            echo "Warning: git commit failed (may be no changes or commit error)"
        fi
    fi
fi

cd - > /dev/null
# Re-enable strict error handling
set -euo pipefail

