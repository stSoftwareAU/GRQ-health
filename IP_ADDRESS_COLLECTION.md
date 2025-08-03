# IP Address Collection for GRQ Health Dashboard

## Overview

The GRQ Health Dashboard now includes automatic IP address collection and display for all monitored machines. This feature allows you to quickly identify and SSH to any machine in your network by displaying both WiFi and Ethernet IP addresses in the Network section of each host card.

## Features

- **Cross-platform support**: Works on macOS, Ubuntu, and Amazon Linux
- **Multiple interface detection**: Automatically detects WiFi and Ethernet interfaces
- **Smart fallback**: Uses modern commands when available, falls back to legacy methods
- **Real-time updates**: IP addresses update automatically when the dashboard refreshes
- **SSH-ready**: Displays IP addresses in a format that's easy to copy for SSH access

## Platform Support

### macOS
- Uses `ifconfig` command to detect interfaces
- Checks `en0` (primary WiFi) and `en1` (primary Ethernet)
- Falls back to `en2` and `en3` if primary interfaces aren't found
- Example output: `"WiFi: 10.0.0.221, Eth: 10.0.0.148"`

### Ubuntu Linux
- Uses modern `ip addr show` command
- Detects WiFi interfaces (`wlan`, `wifi`) and Ethernet interfaces (`eth`, `enp`, `ens`)
- Falls back to `ifconfig` for older systems
- Example output: `"WiFi: 192.168.1.100, Eth: 10.0.0.50"`

### Amazon Linux
- Uses modern `ip addr show` command (same as Ubuntu)
- Detects WiFi interfaces (`wlan`, `wifi`) and Ethernet interfaces (`eth`, `enp`, `ens`)
- Falls back to `ifconfig` for older systems
- Example output: `"WiFi: 192.168.1.100, Eth: 10.0.0.50"`

## Implementation Details

### Data Collection (`run.sh`)

The IP address collection is integrated into the `get_system_info()` function in `run.sh`:

```bash
# Get network connectivity and IP addresses
network_status="unknown"
ip_addresses=""

if command -v ping >/dev/null 2>&1; then
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        network_status="connected"
        
        # Platform-specific IP collection logic
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS implementation
        else
            # Linux implementation
        fi
    else
        network_status="disconnected"
    fi
fi
```

### JSON Data Structure

The collected IP addresses are stored in the JSON data with the `ip_addresses` field:

```json
{
  "hostname": {
    "network_status": "connected",
    "ip_addresses": "WiFi: 10.0.0.221, Eth: 10.0.0.148",
    "uptime": 3600,
    // ... other fields
  }
}
```

### Dashboard Display (`dashboard.js`)

IP addresses are displayed in the Network section of each host card:

```javascript
<div class="col-6">
    <small class="text-muted">Network</small>
    <div class="fw-bold">${data.network_status}</div>
    ${data.ip_addresses ? `<small class="text-muted">${data.ip_addresses}</small>` : ''}
</div>
```

## Testing

### Validation Script

Use the validation script to test IP address collection on any platform:

```bash
./validate_platforms.sh
```

This script will:
1. Detect the platform (macOS/Linux)
2. Check for required commands
3. Test network connectivity
4. Validate IP address collection logic
5. Verify JSON output format
6. Check script syntax

### Manual Testing

To manually test IP address collection:

1. **Run the health script**:
   ```bash
   ./run.sh --force
   ```

2. **Check the JSON output**:
   ```bash
   cat docs/index.json | jq '.[] | select(.ip_addresses) | {hostname: .hostname, ip_addresses: .ip_addresses}'
   ```

3. **View the dashboard**:
   ```bash
   deno run --allow-net --allow-read helpers/server.ts 8000
   ```
   Then open http://localhost:8000 in your browser

## Troubleshooting

### Common Issues

1. **No IP addresses displayed**:
   - Check if the machine has network connectivity
   - Verify that the `run.sh` script has been run recently
   - Check if the machine is running the updated script version

2. **Only one IP address shown**:
   - This is normal if the machine only has one active interface
   - WiFi-only or Ethernet-only machines will show only one IP

3. **IP addresses not updating**:
   - The IP addresses only update when `run.sh` is executed
   - Machines need to run the script to collect their current IP addresses

### Platform-Specific Issues

#### macOS
- If no IP addresses are found, check if interfaces are named differently
- Some Macs may use `en2` for WiFi instead of `en0`
- Use `ifconfig -a` to see all available interfaces

#### Linux
- If using older Linux distributions, ensure `ifconfig` is available
- Some distributions may have different interface naming conventions
- Use `ip addr show` to see all available interfaces

## Security Considerations

- IP addresses are only collected when the machine has network connectivity
- The IP addresses are stored locally in the JSON file
- No external services are contacted for IP address collection
- The feature only collects local network IP addresses, not public IPs

## Future Enhancements

Potential improvements for future versions:
- Public IP address collection (optional)
- IPv6 address support
- Interface status monitoring
- Network speed and bandwidth information
- VPN interface detection

## Support

For issues or questions about IP address collection:
1. Run the validation script: `./validate_platforms.sh`
2. Check the machine's network connectivity
3. Verify that the `run.sh` script is up to date
4. Test on a different platform to isolate platform-specific issues 