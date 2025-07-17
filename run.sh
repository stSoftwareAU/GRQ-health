#!/bin/bash

# Health monitoring script for GRQ-health
# This script checks system health and updates docs/index.json
# Compatible with macOS, Ubuntu, and AWS Linux

set -e

BASE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

cd "${BASE_DIR}"

# Configuration
JSON_FILE="docs/index.json"
HEARTBEAT_THRESHOLD_HOURS=8
HEALTHY_THRESHOLD_HOURS=24

# Parse command line arguments
FORCE_UPDATE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE_UPDATE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --force, -f    Force update regardless of last heartbeat time"
            echo "  --help, -h     Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Get current timestamp
CURRENT_TS=$(date +%s)

# Get hostname (same as other repo)
HOST=$(uname -n)
HOST=${HOST%%.*} # Trim everything after the first period
HOSTNAME=$HOST

# Function to get system information
get_system_info() {
    # Get uptime in seconds
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS: use sysctl for accurate uptime
        boot_time=$(sysctl -n kern.boottime | awk -F'[ ,]' '{print $4}')
        now_time=$(date +%s)
        if [[ -n "$boot_time" && -n "$now_time" ]]; then
            uptime_sec=$((now_time - boot_time))
        else
            uptime_sec=0
        fi
    else
        # Linux: use /proc/uptime for accurate uptime
        if [ -f /proc/uptime ]; then
            uptime_sec=$(cat /proc/uptime | awk '{print int($1)}')
        else
            # Fallback to parsing uptime command
            uptime_output=$(uptime)
            # Extract the uptime part after "up"
            uptime_part=$(echo "$uptime_output" | sed -n 's/.*up \([^,]*\).*/\1/p')
            
            # Parse different formats: "2 days, 3:45", "3:45", "45 min", "2 hours", etc.
            if [[ $uptime_part =~ ([0-9]+)\ days? ]]; then
                days=${BASH_REMATCH[1]}
            else
                days=0
            fi
            
            if [[ $uptime_part =~ ([0-9]+):([0-9]+) ]]; then
                hours=${BASH_REMATCH[1]}
                mins=${BASH_REMATCH[2]}
            elif [[ $uptime_part =~ ([0-9]+)\ hours? ]]; then
                hours=${BASH_REMATCH[1]}
                mins=0
            elif [[ $uptime_part =~ ([0-9]+)\ min ]]; then
                hours=0
                mins=${BASH_REMATCH[1]}
            else
                hours=0
                mins=0
            fi
            
            uptime_sec=$((days * 86400 + hours * 3600 + mins * 60))
        fi
    fi
    
    # Get disk space for the current working directory (where the script runs from)
    if command -v df >/dev/null 2>&1; then
        # Get the current working directory
        current_dir=$(pwd)
        
        # Use df with human-readable output and get the second line (first filesystem)
        df_output=$(df -h "$current_dir" | awk 'NR==2')
        
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS - handle Gi suffix
            total_disk=$(echo "$df_output" | awk '{print $2}' | sed 's/Gi//')
            free_disk_space=$(echo "$df_output" | awk '{print $4}' | sed 's/Gi//')
            used_disk=$(echo "$df_output" | awk '{print $3}' | sed 's/Gi//')
        else
            # Linux/AWS - handle G suffix and other variations
            total_disk=$(echo "$df_output" | awk '{print $2}' | sed 's/G//; s/Ti//; s/Mi//')
            free_disk_space=$(echo "$df_output" | awk '{print $4}' | sed 's/G//; s/Ti//; s/Mi//')
            used_disk=$(echo "$df_output" | awk '{print $3}' | sed 's/G//; s/Ti//; s/Mi//')
        fi
        
        # Calculate disk usage percentage - handle different units
        if [[ "$total_disk" =~ ^[0-9]+$ && "$used_disk" =~ ^[0-9]+$ ]]; then
            disk_usage_percent=$(echo "scale=1; $used_disk * 100 / $total_disk" | bc -l 2>/dev/null || echo "0")
        else
            disk_usage_percent="0"
        fi
    else
        free_disk_space="unknown"
        disk_usage_percent="0"
    fi
    
    # Get memory usage
    if command -v free >/dev/null 2>&1; then
        # Linux - use free command
        total_mem=$(free -m | awk 'NR==2{print $2}')
        used_mem=$(free -m | awk 'NR==2{print $3}')
        mem_usage_percent=$(echo "scale=1; $used_mem * 100 / $total_mem" | bc -l 2>/dev/null || echo "0")
    elif command -v vm_stat >/dev/null 2>&1; then
        # macOS - improved memory calculation
        vm_stat_output=$(vm_stat)
        total_mem=$(sysctl -n hw.memsize 2>/dev/null | awk '{print $1 / 1024 / 1024 / 1024}')
        if [[ -z "$total_mem" ]]; then
            total_mem=0
        fi
        
        # Calculate used memory from vm_stat
        active_pages=$(echo "$vm_stat_output" | awk '/Pages active:/ {print $3}' | tr -d '.')
        wired_pages=$(echo "$vm_stat_output" | awk '/Pages wired down:/ {print $4}' | tr -d '.')
        compressed_pages=$(echo "$vm_stat_output" | awk '/Pages occupied by compressor:/ {print $5}' | tr -d '.')
        
        if [[ -n "$active_pages" && -n "$wired_pages" && -n "$compressed_pages" ]]; then
            used_mem_gb=$(echo "scale=2; ($active_pages + $wired_pages + $compressed_pages) * 4096 / 1024 / 1024 / 1024" | bc -l 2>/dev/null || echo "0")
            mem_usage_percent=$(echo "scale=1; $used_mem_gb * 100 / $total_mem" | bc -l 2>/dev/null || echo "0")
        else
            mem_usage_percent="0"
        fi
    else
        mem_usage_percent="0"
    fi
    
    # Get CPU load (average over last 5 minutes)
    if command -v uptime >/dev/null 2>&1; then
        # Get the 5-minute load average (second value)
        cpu_load_raw=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $2}' | sed 's/,//')
        if [[ -z "$cpu_load_raw" && "$OSTYPE" == "darwin"* ]]; then
            # Fallback for macOS if blank
            cpu_load_raw=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' | tr -d '{}')
        fi
        
        # Convert load average to percentage
        if [[ "$cpu_load_raw" =~ ^[0-9]*\.?[0-9]+$ ]]; then
            # Get number of CPU cores - cross-platform
            if [[ "$OSTYPE" == "darwin"* ]]; then
                cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "1")
            else
                # Linux - try multiple methods
                if command -v nproc >/dev/null 2>&1; then
                    cpu_cores=$(nproc 2>/dev/null || echo "1")
                elif [ -f /proc/cpuinfo ]; then
                    cpu_cores=$(grep -c processor /proc/cpuinfo 2>/dev/null || echo "1")
                else
                    cpu_cores="1"
                fi
            fi
            
            # Convert load average to percentage (load per core * 100)
            cpu_load_percent=$(echo "scale=1; $cpu_load_raw * 100 / $cpu_cores" | bc -l 2>/dev/null || echo "0")
            cpu_load="${cpu_load_percent}%"
        else
            cpu_load="0%"
        fi
    else
        cpu_load="0%"
    fi
    
    # Get timezone
    timezone=$(date +%Z)
    
    # Get OS info - cross-platform
    if [[ "$OSTYPE" == "darwin"* ]]; then
        os_info=$(sw_vers -productName 2>/dev/null || echo "macOS")
        os_version=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
    else
        # Linux - try multiple methods
        if [ -f /etc/os-release ]; then
            # Modern Linux systems
            os_info=$(source /etc/os-release && echo $NAME)
            os_version=$(source /etc/os-release && echo $VERSION)
        elif [ -f /etc/lsb-release ]; then
            # Ubuntu/Debian
            os_info=$(source /etc/lsb-release && echo $DISTRIB_ID)
            os_version=$(source /etc/lsb-release && echo $DISTRIB_RELEASE)
        elif [ -f /etc/redhat-release ]; then
            # RHEL/CentOS/Amazon Linux
            os_info=$(cat /etc/redhat-release | awk '{print $1}')
            os_version=$(cat /etc/redhat-release | awk '{print $3}')
        else
            # Fallback
            os_info=$(uname -s)
            os_version=$(uname -r)
        fi
    fi
    
    # Get network connectivity
    network_status="unknown"
    if command -v ping >/dev/null 2>&1; then
        if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
            network_status="connected"
        else
            network_status="disconnected"
        fi
    fi
    
    # Ensure uptime_sec is a number
    if [[ ! "$uptime_sec" =~ ^[0-9]+$ ]]; then
        uptime_sec=0
    fi
    
    echo "{\"uptime\": $uptime_sec, \"free_disk_space\": \"$free_disk_space\", \"disk_usage_percent\": \"$disk_usage_percent\", \"mem_usage_percent\": \"$mem_usage_percent\", \"cpu_load\": \"$cpu_load\", \"timezone\": \"$timezone\", \"os_info\": \"$os_info\", \"os_version\": \"$os_version\", \"network_status\": \"$network_status\"}"
}

# Function to check if we need to update
should_update() {
    if [ ! -f "$JSON_FILE" ]; then
        return 0  # File doesn't exist, need to create
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq is required but not found. Please install jq to continue."
        echo "Installation:"
        echo "  macOS: brew install jq"
        echo "  Ubuntu/Debian: sudo apt-get install jq"
        echo "  Amazon Linux: sudo yum install jq"
        exit 1
    fi
    
    # If force update is requested, always update
    if [ "$FORCE_UPDATE" = true ]; then
        echo "Force update requested - updating regardless of last heartbeat time"
        return 0
    fi
    
    local last_heartbeat=$(jq -r ".\"$HOSTNAME\".heart_beat_ts // 0" "$JSON_FILE" 2>/dev/null || echo "0")
    local hours_since_last=$(( (CURRENT_TS - last_heartbeat) / 3600 ))
    echo "[DEBUG] last_heartbeat=$last_heartbeat, hours_since_last=$hours_since_last, current_ts=$CURRENT_TS"
    if [ $hours_since_last -ge $HEARTBEAT_THRESHOLD_HOURS ]; then
        return 0  # Need to update
    else
        return 1  # No update needed
    fi
}

# Function to update JSON file
update_json() {
    local system_info=$(get_system_info)
    
    # Create backup (tmp file, clean up after)
    if [ -f "$JSON_FILE" ]; then
        cp "$JSON_FILE" "${JSON_FILE}.tmp"
    fi
    
    # Update or create JSON file
    if [ -f "$JSON_FILE" ]; then
        # Update existing file - preserve existing attributes
        jq --arg host "$HOSTNAME" \
           --arg ts "$CURRENT_TS" \
           --argjson info "$system_info" \
           '.[$host] = (.[$host] // {} + $info + {"heart_beat_ts": ($ts | tonumber)})' \
           "$JSON_FILE" > "${JSON_FILE}.tmp2" && mv "${JSON_FILE}.tmp2" "$JSON_FILE"
    else
        # Create new file
        jq --arg host "$HOSTNAME" \
           --arg ts "$CURRENT_TS" \
           --argjson info "$system_info" \
           '{($host): ($info + {"heart_beat_ts": ($ts | tonumber)})}' \
           > "$JSON_FILE"
    fi
    # Clean up tmp backup
    [ -f "${JSON_FILE}.tmp" ] && rm -f "${JSON_FILE}.tmp"
    [ -f "${JSON_FILE}.tmp2" ] && rm -f "${JSON_FILE}.tmp2"
    
    echo "Updated health information for $HOSTNAME"
}

# Function to commit and push changes
commit_and_push() {
    if [ -d ".git" ]; then
        git add docs/
        git commit -m "Update health status for $HOSTNAME at $(date -r $CURRENT_TS)" 2>/dev/null || true
        
        # Try to push (might fail if no remote or no changes)
        if git push 2>/dev/null; then
            echo "Changes pushed to remote repository"
        else
            echo "No changes to push or push failed"
        fi
    else
        echo "Not a git repository, skipping commit/push"
        exit 1
    fi
}

# Main execution
main() {
    if should_update; then
        echo "Updating health information..."
        update_json
        # After updating JSON, copy log if present
        # Copy node.log if present
        LOG_SRC="$HOME/logs/node.log"
        LOG_DEST="docs/$HOSTNAME/node.log"
        if [ -f "$LOG_SRC" ]; then
            mkdir -p "docs/$HOSTNAME"
            cp "$LOG_SRC" "$LOG_DEST"
        fi
        commit_and_push
    else
        exit 0
    fi
}

# Run main function
main "$@" 