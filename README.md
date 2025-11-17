# GRQ Health Monitoring System

A distributed health monitoring system that tracks the status of multiple hosts across different operating systems and timezones. The system provides a beautiful web dashboard to visualize host health status with location tracking, historical records, and smart health logic.

## 🤖 AI Assistant Instructions

**IMPORTANT: This README serves as the primary specification document for the AI assistant working on this project.**

### Before Making Any Changes:
1. **ALWAYS read this entire README first** to understand the current system architecture and specifications
2. **Check the current version** in `run.sh` and increment it for any code changes
3. **Run `./update_version.sh`** after making changes to sync version across all files
4. **Update this README** if you modify system behavior, add features, or change specifications
5. **Test changes** on both desktop and mobile views when applicable

### Current System Specifications:

#### Log Viewer Auto-Scroll Behavior:
- **Function**: `scrollToFirstIssue()` in `log-viewer.html`
- **Current Logic**: 
  1. Find the first issue of any type in DOM order (error, stack trace, or warning)
  2. Scroll to that first issue
  3. If no issues found, stay at the top
- **Highlighted Issues**: ERROR, Exception, Error:, ⚠️ (warning emoji), WARNING, Warning:, DEBUG:
- **Stack Trace Detection**: 
  - JavaScript stack traces: Lines matching `/^\s+at /` pattern
  - C stack traces: Lines matching `/^\s+\d+\s+[^\s]+\s+0x[0-9a-fA-F]+/` pattern (allows periods, hyphens, and other valid characters in binary/library names, requires hex address to avoid false positives from git messages)
- **All issues are counted** in the dashboard exception count

#### Exception Detection in run.sh:
- **Stack traces**: Lines with "Exception", "Error", "MEMETIC" followed by stack trace lines
- **Missing commands**: "No such file or directory" errors
- **Warning emojis**: Lines containing "⚠️" 
- **Permission errors**: "Permission denied", "access denied", "EACCES"
- **All exceptions trigger health updates** regardless of heartbeat timing

#### Market Feed Repository Freshness:
- **Config**: `config/repo_feeds.json` lists every background repo to track with its git URL and short display name (usually the `GRQ-` prefix removed for readability)
- **Generator**: `helpers/repo_feed_health.ts` (run with Deno 2) resolves the latest commit timestamp on the default branch for each configured repo and writes `docs/repos.json`. Always run the script with `--allow-env --allow-net=api.github.com --allow-read=config --allow-write=docs`.
- **Output**: `docs/repos.json` contains an array of records with the repo `name`, canonical `repo` slug, `last_commit_ts` (seconds since epoch), derived `status`, and optional `error_message` when the GitHub API could not be queried
- **Thresholds**: 
  - `healthy` when the last commit is within 36 hours
  - `warning` when the last commit is older than 36 hours
  - `error` when the last commit is older than 72 hours
- **Deploy behaviour**: The GitHub Actions workflow logs `::warning`/`::error` annotations for stale repos but always continues deployment so Pages can surface the issue
- **Visualisation**: `docs/dashboard.js` and `docs/simple.html` fetch `docs/repos.json` and show the warning/error counts alongside the standard host health metrics

#### Version Management:
- **Primary version**: Stored in `run.sh` VERSION variable
- **Auto-sync**: `./update_version.sh` updates all HTML/JS files
- **Required**: Increment version for any code changes

## Features

- **Cross-platform compatibility**: Works on macOS, Ubuntu, and AWS Linux
- **Automatic health checks**: Monitors uptime, disk space, memory usage, CPU load, and network connectivity
- **Smart updates**: Only updates when heartbeat is older than 12 hours
- **Beautiful dashboard**: Modern web interface with real-time health status
- **Location tracking**: Shows where each host is located with emoji indicators
- **Historical records**: Maintains information about dead machines and MacBook Airs
- **Smart health logic**: 
  - Known dead machines don't affect system health
  - MacBook Airs are expected to be offline and only marked critical after 7 days
  - Slow machines are identified and tracked separately
- **Dynamic page title**: Changes between "GRQ Healthy" and "GRQ Unhealthy" for uptime monitoring
- **GitHub Pages integration**: Automatic deployment of the dashboard
- **Timezone awareness**: Handles hosts in different timezones correctly

## System Requirements

- Bash shell
- `jq` (optional, for better JSON handling)
- `git` (for automatic commits and pushes)
- Basic Unix tools (`uptime`, `df`, `free`, `ping`, etc.)

## Quick Start

1. **Clone the repository**:
   ```bash
   git clone <your-repo-url>
   cd GRQ-health
   ```

2. **Make the script executable**:
   ```bash
   chmod +x run.sh
   ```

3. **Run the health check**:
   ```bash
   ./run.sh
   ```

4. **View the dashboard**: The dashboard will be available at your GitHub Pages URL once you push the changes.

## How It Works

### The `run.sh` Script

The script performs the following operations:

1. **System Information Collection**:
   - Uptime (in seconds)
   - Free disk space (in GB)
   - Memory usage percentage
   - CPU load average
   - Operating system information
   - Network connectivity status
   - Timezone information

2. **Health Check Logic**:
   - Checks if the last heartbeat was more than 12 hours ago
   - Only updates if an update is needed (prevents unnecessary writes)
   - Creates backup of existing JSON file before updates

3. **Data Storage**:
   - Updates `docs/index.json` with current host information
   - Uses hostname as the key for each host's data
   - Maintains timestamp of last heartbeat

4. **Git Integration**:
   - Automatically commits changes
   - Pushes to remote repository
   - Triggers GitHub Pages deployment

### Enhanced JSON Data Structure

The system uses a simple structure where each hostname is a key:

```json
{
  "GRQ-23": {
    "uptime": 86400,
    "free_disk_space": "50",
    "disk_usage_percent": "39.7",
    "mem_usage_percent": "65.2",
    "cpu_load": "1.25",
    "timezone": "AEST",
    "os_info": "macOS",
    "os_version": "15.5",
    "network_status": "connected",
    "heart_beat_ts": 1704067200,
    "location": "Newport Office",
    "info": "Mac m4",
    "emoji": "🍭"
  },
  "GRQ-2": {
    "death_date": "5 May 2024",
    "location": "Silicon Heaven",
    "emoji": "💀",
    "os_info": "",
    "info": ""
  },
  "Tina's": {
    "location": "Out 'n about",
    "emoji": "🕊️",
    "os_info": "Mac",
    "info": "Mac m3",
    "last_seen": "2 Jun 2025",
    "sample_rate": "1m 1s"
  }
}
```

### Repo Freshness JSON (`docs/repos.json`)

```json
{
  "generated_at": 1752806400,
  "repos": [
    {
      "name": "FX",
      "repo": "stSoftwareAU/GRQ-FX",
      "last_commit_ts": 1752806400,
      "status": "healthy"
    },
    {
      "name": "shareprices2025Q3",
      "repo": "stSoftwareAU/GRQ-shareprices2025Q3",
      "last_commit_ts": 1752720000,
      "status": "warning"
    },
    {
      "name": "commodities",
      "repo": "stSoftwareAU/GRQ-commodities",
      "last_commit_ts": 1752600000,
      "status": "error",
      "error_message": "Failed to fetch commits (404 Not Found)"
    }
  ]
}
```

The dashboard highlights entries more than 36 hours old as warnings and entries more than 72 hours old as errors. When the GitHub API cannot be reached, the tool records the failure (with `error_message`) but keeps deployment running so the dashboard can report the outage.

### Enhanced Health Status Classification

- **Healthy**: 
  - Heartbeat within 24 hours
  - Disk usage under 75%
  - OS version up to date
- **Warning**: 
  - Disk usage over 75%
  - Outdated OS version
  - Heartbeat within 24 hours
- **Critical**: 
  - No heartbeat for 24+ hours (except MacBook Airs)
  - MacBook Airs only marked critical after 7 days offline
- **Dead**: Known dead machines (don't affect system health)
- **Historical**: MacBook Airs and other mobile devices

## Dashboard Features

The enhanced web dashboard (`docs/index.html`) provides:

- **Real-time statistics**: Total hosts, healthy, warning, and critical counts
- **Host cards**: Individual cards for each host with detailed information
- **Location display**: Shows where each host is located with emoji indicators
- **Historical section**: Displays dead machines and MacBook Airs
- **Filtering**: Filter by health status (all, healthy, warning, critical)
- **Auto-refresh**: Updates every 60 seconds
- **Responsive design**: Works on desktop and mobile devices
- **Visual indicators**: Color-coded status indicators and borders
- **Dynamic title**: Changes between "GRQ Healthy" and "GRQ Unhealthy"

### Emoji Legend

- 💀 Dead machines (in Silicon Heaven)
- 👌 Healthy machines
- 🐌 Slow machines
- 🏭 Mac Studio/Workstation
- 👴🏻 Old Linux machines
- 🍭 Mac m4 machines
- 🚀 High-performance machines
- 🕊️ MacBook Airs (mobile)

## Manual Host Management

You can manually edit `docs/index.json` to add or modify hosts:

### Adding a New Active Host
```json
{
  "GRQ-24": {
    "uptime": 0,
    "free_disk_space": "100",
    "disk_usage_percent": "20",
    "mem_usage_percent": "10",
    "cpu_load": "5%",
    "timezone": "AEST",
    "os_info": "macOS",
    "os_version": "15.5",
    "network_status": "connected",
    "heart_beat_ts": 1752728062,
    "location": "Newport Office",
    "info": "New Mac",
    "emoji": "🍭"
  }
}
```

### Marking a Host as Dead
```json
{
  "GRQ-25": {
    "death_date": "15 Jun 2025",
    "location": "Silicon Heaven",
    "emoji": "💀",
    "os_info": "Linux",
    "info": "Old server"
  }
}
```

### Adding a MacBook Air
```json
{
  "New MacBook": {
    "location": "Out 'n about",
    "emoji": "🕊️",
    "os_info": "Mac",
    "info": "Mac m4",
    "last_seen": "15 Jun 2025",
    "sample_rate": "2m 30s"
  }
}
```

## Setup Instructions

### 1. Repository Setup

1. Create a new GitHub repository
2. Clone it to your local machine
3. Copy the files from this project
4. Enable GitHub Pages in your repository settings:
   - Go to Settings → Pages
   - Source: Deploy from a branch
   - Branch: main/master
   - Folder: /docs

### 2. Host Configuration

For each host you want to monitor:

1. Clone the repository to the host
2. Make the script executable: `chmod +x run.sh`
3. Set up a cron job for regular execution:
   ```bash
   # Edit crontab
   crontab -e
   
   # Add this line to run every 6 hours
   0 */6 * * * /path/to/GRQ-health/run.sh
   ```

### 3. Dependencies Installation

#### Ubuntu/Debian:
```bash
sudo apt update
sudo apt install jq bc
```

#### macOS:
```bash
brew install jq bc
```

#### AWS Linux/Amazon Linux:
```bash
sudo yum install jq bc
# or for newer versions:
sudo dnf install jq bc
```

## Configuration

You can modify the following variables in `run.sh`:

- `HEARTBEAT_THRESHOLD_HOURS`: How often to update (default: 12 hours)
- `HEALTHY_THRESHOLD_HOURS`: What constitutes "healthy" status (default: 24 hours)
- `JSON_FILE`: Path to the JSON data file (default: docs/index.json)

## Uptime Monitoring

The page title automatically changes to:
- **"GRQ Healthy"** when all active hosts are healthy
- **"GRQ Unhealthy"** when any active host is critical

This allows uptime monitoring services to check the page title for system health status.

## Troubleshooting

### Common Issues

1. **Script fails to run**:
   - Check if bash is available: `which bash`
   - Ensure script is executable: `chmod +x run.sh`
   - Check for required commands: `which uptime df ping`

2. **JSON parsing errors**:
   - Install `jq`: The script will work without it but with limited functionality
   - Check JSON syntax: `jq . docs/index.json`

3. **Git push fails**:
   - Ensure you have write access to the repository
   - Check if remote is configured: `git remote -v`
   - Verify authentication is set up

4. **Dashboard not updating**:
   - Check GitHub Pages settings
   - Verify the workflow ran successfully in Actions tab
   - Clear browser cache

### Debug Mode

Run the script with debug output:
```bash
bash -x run.sh
```

## Security Considerations

- The script runs with the same permissions as the user executing it
- No sensitive information is collected or stored
- Hostnames are used as identifiers (ensure they don't contain sensitive data)
- Consider using SSH keys for git authentication instead of passwords

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. **Always update the version number** in `run.sh` when making code changes
5. **Run the version update script**: `./update_version.sh` to sync version across all files
6. Test on different operating systems
7. Submit a pull request

### Version Management

When making code changes, you must:
1. Update the `VERSION` variable in `run.sh` (e.g., from "1.0.32" to "1.0.33")
2. Run `./update_version.sh` to automatically update version numbers in all HTML and JavaScript files
3. This ensures version consistency across the entire project

## License

This project is open source. Feel free to modify and distribute as needed.

## Support

For issues and questions:
1. Check the troubleshooting section
2. Review the script output for error messages
3. Open an issue in the GitHub repository

## Documentation

For detailed documentation about the dashboard features and data structure, see [docs/README.md](docs/README.md).