#!/bin/bash
# Repo Health Tracking Snippet
# Add this to the end of your market load scripts (after git commit/push)
#
# Usage: Add this after a successful git push, customizing REPO_NAME

if [ $? -eq 0 ]; then
  ## Update health tracking
  GRQ_HEALTH_DIR="../GRQ-health"  # Adjust if GRQ-health is elsewhere
  GRQ_HEALTH_REPO="https://github.com/stSoftwareAU/GRQ-health.git"  # Use HTTPS for cloning

  # If GRQ-health doesn't exist, clone it
  if [ ! -d "$GRQ_HEALTH_DIR" ]; then
      git clone --depth=1 "$GRQ_HEALTH_REPO" "$GRQ_HEALTH_DIR"
  fi

  # Update repo health
  "${GRQ_HEALTH_DIR}/helpers/repos.sh" "Dividends"  # CHANGE THIS to your repo name
fi

