# Repo Health Tracking Snippet

Add this snippet to the end of your market load scripts (after git commit/push) to track repo health in GRQ-health.

## Simple Version (Copy-Paste Ready)

Add this to your script after a successful `git push`, customizing the repo name:

```bash
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
```

## Example: Adding to dividends.sh

Add this snippet at the end of `dividends.sh`, after the git commit/push:

```bash
# ... existing code ...
git commit -m "Dividends on ${HOST}@${TODAY}"
git push

if [ $? -eq 0 ]; then
  ## Update health tracking
  GRQ_HEALTH_DIR="../GRQ-health"  # Adjust if GRQ-health is elsewhere
  GRQ_HEALTH_REPO="https://github.com/stSoftwareAU/GRQ-health.git"  # Use HTTPS for cloning

  # If GRQ-health doesn't exist, clone it
  if [ ! -d "$GRQ_HEALTH_DIR" ]; then
      git clone --depth=1 "$GRQ_HEALTH_REPO" "$GRQ_HEALTH_DIR"
  fi

  # Update repo health
  "${GRQ_HEALTH_DIR}/helpers/repos.sh" "Dividends"
fi
```

## How It Works

1. The snippet only runs if `git push` succeeds (`$? -eq 0`)
2. Checks if GRQ-health directory exists, clones it if missing
3. Calls `helpers/repos.sh` with your repo name
4. The script (`repos.sh`) handles:
   - Pulling latest changes from GRQ-health
   - Updating `docs/repos.json` with your repo name and current UTC timestamp
   - Committing and pushing the update
   - Conflict recovery if multiple machines update simultaneously

## Dashboard Status Logic

The dashboard (`dashboard.js`) automatically calculates status based on `last_commit_ts`:
- **ERROR** (red): Last commit more than 48 hours ago
- **WARNING** (yellow): Last commit more than 24 hours ago  
- **OK** (green): Last commit within 24 hours

## Customization

- **Repo Name**: Change `"Dividends"` in the last line to your repo's display name (e.g., "FX", "Commodities", "SharePrices")
- **GRQ_HEALTH_DIR**: Adjust path if GRQ-health is in a different location relative to your script
- **GRQ_HEALTH_REPO**: Only change if using a different repository URL

## Notes

- The snippet only runs if `git push` succeeds, so failed pushes won't update health tracking
- `repos.sh` handles all git operations (pull, commit, push) internally with conflict recovery
- The script uses `--depth=1` for cloning to save time and disk space

