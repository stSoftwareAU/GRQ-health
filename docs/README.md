# GRQ Health Dashboard

A real-time monitoring dashboard for the GRQ system that displays the health status of all hosts with location information, emojis, and historical data.

## Features

- **Real-time Health Monitoring**: Tracks uptime, disk usage, memory, CPU load, and network status
- **Location Display**: Shows where each host is located with emoji indicators
- **Historical Records**: Maintains information about dead machines and MacBook Airs
- **Smart Health Logic**: 
  - Known dead machines are marked as "dead" and don't affect system health
  - MacBook Airs are expected to be offline and only marked critical after 7 days
  - Slow machines are identified and tracked separately
- **Dynamic Page Title**: Changes between "GRQ Healthy" and "GRQ Unhealthy" for uptime monitoring
- **Auto-refresh**: Updates every 60 seconds

## Data Structure

The system uses a simple `index.json` file where each hostname is a key:

### Active Hosts
Currently active machines that report health data:
```json
{
  "GRQ-23": {
    "uptime": 799823,
    "free_disk_space": "257",
    "disk_usage_percent": "39.7",
    "mem_usage_percent": "15.2",
    "cpu_load": "18.8%",
    "timezone": "AEST",
    "os_info": "macOS",
    "os_version": "15.5",
    "network_status": "connected",
    "heart_beat_ts": 1752728062,
    "location": "Newport Office",
    "info": "Mac m4",
    "emoji": "🍭"
  }
}
```

### Multi-user Hosts
Some machines run multiple automated users (e.g. `sloth`, `rocket`, `elephant`). In this case the host entry contains a `users` map. The dashboard **treats the host heartbeat as unhealthy if any discovered user is stale**, so one user's updates can't mask another user's stuck state.

```json
{
  "GRQ-21": {
    "heart_beat_ts": 1752728062,
    "users": {
      "sloth": { "heart_beat_ts": 1752728000, "version": "1.0.64" },
      "rocket": { "heart_beat_ts": 1752728062, "version": "1.0.64" }
    }
  }
}
```

### Dead Machines
Machines that have died (don't affect system health):
```json
{
  "GRQ-2": {
    "death_date": "5 May 2024",
    "location": "Silicon Heaven",
    "emoji": "💀",
    "os_info": "",
    "info": ""
  }
}
```

### MacBook Airs
Mobile machines that are expected to be offline:
```json
{
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

## Emoji Legend

- 💀 Dead machines (in Silicon Heaven)
- 👌 Healthy machines
- 🐌 Slow machines
- 🏭 Mac Studio/Workstation
- 👴🏻 Old Linux machines
- 🍭 Mac m4 machines
- 🚀 High-performance machines
- 🕊️ MacBook Airs (mobile)

## Health Status Logic

### Healthy
- Heartbeat within 24 hours
- Disk usage under 90%
- OS version up to date

### Warning
- Disk usage at or above 90% (with hysteresis: clears at or below 87%)
- Outdated OS version
- Heartbeat within 24 hours

### Critical
- No heartbeat for 24+ hours (except MacBook Airs)
- MacBook Airs only marked critical after 7 days offline

### Dead
- Known dead machines (don't affect system health)

### Historical
- MacBook Airs and other mobile devices

## Manual Updates

You can manually edit `docs/index.json` to:
- Add new hosts with health data
- Add dead machines with `death_date` attribute
- Add MacBook Airs with location and emoji
- Update location, emoji, or info fields

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

## Uptime Monitoring

The page title automatically changes to:
- **"GRQ Healthy"** when all active hosts are healthy
- **"GRQ Unhealthy"** when any active host is critical

This allows uptime monitoring services to check the page title for system health status.

## File Structure

```
docs/
├── index.html          # Main dashboard page
├── index.json          # Host data
├── dashboard.js        # Dashboard functionality
├── styles.css          # Styling
├── medical-check.png   # Favicon
└── [hostname]/         # Individual host log directories
    └── node-<user>.log # Per-user log file (one per unix user)
```

## Browser Compatibility

The dashboard uses modern web technologies and is compatible with:
- Chrome/Chromium (recommended)
- Firefox
- Safari
- Edge

## Auto-refresh

The dashboard automatically refreshes every 60 seconds to show the latest health data. You can also manually refresh the page for immediate updates. 