#!/bin/bash
# Repo Health Tracking Snippet
# Add this to the end of your market load scripts (after git commit/push)
#
# Usage: Add this after a successful git push, customizing REPO_NAME

if [ $? -eq 0 ]; then
  ## Update health tracking
  GRQ_HEALTH_DIR="../GRQ-health"
  GRQ_HEALTH_REPO="git@github.com:stSoftwareAU/GRQ-health.git"

  # If GRQ-health doesn't exist, clone it; otherwise pull latest
  if [ ! -d "$GRQ_HEALTH_DIR" ]; then
      git clone --depth=1 "$GRQ_HEALTH_REPO" "$GRQ_HEALTH_DIR"
  else
      git -C "$GRQ_HEALTH_DIR" pull
  fi

  # Update repo health
  "${GRQ_HEALTH_DIR}/helpers/repos.sh" "Dividends"  # CHANGE THIS to your repo name
fi

