# Repo Health Tracking Snippet

Add this snippet to the end of your market load scripts (after git commit/push) to track repo health in GRQ-health.

## Simple Version (Copy-Paste Ready)

Add this to your script after a successful `git push`, customising the repo name:

```bash
if [ $? -eq 0 ]; then
  ## Update health tracking
  GRQ_HEALTH_DIR="../GRQ-health"
  GRQ_HEALTH_REPO="git@github.com:stSoftwareAU/GRQ-health.git"

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
  GRQ_HEALTH_DIR="../GRQ-health"
  GRQ_HEALTH_REPO="git@github.com:stSoftwareAU/GRQ-health.git"

  # If GRQ-health doesn't exist, clone it
  if [ ! -d "$GRQ_HEALTH_DIR" ]; then
      git clone --depth=1 "$GRQ_HEALTH_REPO" "$GRQ_HEALTH_DIR"
  fi

  # Update repo health
  "${GRQ_HEALTH_DIR}/helpers/repos.sh" "Dividends"
fi
```

## Reporting failures with a log file

External task runners (for example, a Quality gate in a worker repo) often want
to report **both** successful and failed runs. When a task fails, capture its
output to a log file and hand that log to `repos.sh` with the `--failed` and
`--log` flags. The dashboard will then show the most recent failure alongside
its log, and operators can inspect what went wrong without digging into the
host.

### Copy-paste pattern (inline if/else)

```bash
# Example: wrapping a quality check
LOG_FILE="$HOME/logs/quality.log"

if ./quality.sh >"$LOG_FILE" 2>&1; then
    ./helpers/repos.sh "Quality"
else
    EXIT=$?
    ./helpers/repos.sh "Quality" --failed --log "$LOG_FILE" --exit-code "$EXIT"
    exit "$EXIT"
fi
```

### Single-function helper

If you prefer not to hand-roll the if/else, `source` the helper library and
call `report_repo_health` right after the task. The function inspects `$?` of
the previous command and picks the success or failure path automatically:

```bash
# Source the helper library once
source "../GRQ-health/helpers/repo-health-snippet.sh"

LOG_FILE="$HOME/logs/quality.log"
./quality.sh >"$LOG_FILE" 2>&1
report_repo_health "Quality" "$LOG_FILE" || exit $?
```

The helper honours the `GRQ_HEALTH_DIR` and `GRQ_HEALTH_REPO` environment
variables if you need to point at a different checkout or remote. It preserves
the original exit code so the caller can propagate a non-zero status.

### What the failure flags do

| Flag | Required? | Purpose |
|------|-----------|---------|
| `--failed` | Yes (for a failure report) | Marks the call as a failure report. `last_commit_ts` is left untouched. |
| `--log <path>` | Yes (with `--failed`) | Path to the log file to store alongside the failure entry. Use `-` to read from stdin. |
| `--exit-code <N>` | Optional | Records the non-zero exit status in `last_failure_exit_code`. |
| `--message <text>` | Optional | Records a short one-line summary in `last_failure_message`. |

Only invoke `--failed` when the task actually failed. A successful run should
still use the plain `repos.sh "<task>"` form so that `last_commit_ts` is
updated.

### ⚠️ Security: logs are published publicly

Log files handed to `repos.sh` are copied into `docs/logs/<task-slug>/` inside
the GRQ-health repository and **committed to the public GitHub Pages site**.

- Before calling `repos.sh --failed --log`, the caller MUST redact any
  secrets, credentials, tokens, internal hostnames, customer data, or anything
  else that should not be published.
- Never pass a raw log that may include environment dumps, `set -x` traces of
  commands that contain secrets, or authentication headers.
- If in doubt, redact aggressively or capture a summary log instead of the
  full transcript.

### Log retention

`repos.sh` keeps the **last 5 log files per task**. Older logs are deleted
automatically when a new failure is recorded. Task names are converted to safe
directory slugs (alphanumeric, hyphens, underscores) before being used as a
directory name, so `ScoreClient:luke` becomes `docs/logs/ScoreClient-luke/`.

### Backwards compatibility

Existing callers that only report successes continue to work without changes.
The failure-reporting flags are additive: the default invocation
(`repos.sh "<task>"`) is unchanged and records a successful run exactly as
before.

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

## Customisation

- **Repo Name**: Change `"Dividends"` in the last line to your repo's display name (e.g., "FX", "Commodities", "SharePrices")
- **GRQ_HEALTH_DIR**: Adjust path if GRQ-health is in a different location relative to your script
- **GRQ_HEALTH_REPO**: Only change if using a different repository URL

## Notes

- The success-only snippet only runs if `git push` succeeds, so failed pushes won't update health tracking
- `repos.sh` handles all git operations (pull, commit, push) internally with conflict recovery
- The script uses `--depth=1` for cloning to save time and disk space
- For callers that also want to report **failures**, see the
  [Reporting failures with a log file](#reporting-failures-with-a-log-file)
  section above
