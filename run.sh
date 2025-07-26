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
    
    # Get disk space - cross-platform approach
    if command -v df >/dev/null 2>&1; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS - check the main data volume (/System/Volumes/Data) which contains user data
            # This is more accurate than checking the current directory which might be on system volume
            df_output=$(df -h "/System/Volumes/Data" 2>/dev/null | awk 'NR==2')
            if [[ -z "$df_output" ]]; then
                # Fallback to current directory if data volume not accessible
                current_dir=$(pwd)
                df_output=$(df -h "$current_dir" | awk 'NR==2')
            fi
            
            # macOS - handle Gi suffix
            total_disk=$(echo "$df_output" | awk '{print $2}' | sed 's/Gi//')
            free_disk_space=$(echo "$df_output" | awk '{print $4}' | sed 's/Gi//')
            used_disk=$(echo "$df_output" | awk '{print $3}' | sed 's/Gi//')
        else
            # Linux/AWS - check current directory
            current_dir=$(pwd)
            df_output=$(df -h "$current_dir" | awk 'NR==2')
            
            # Linux/AWS - handle G suffix and other variations
            total_disk=$(echo "$df_output" | awk '{print $2}' | sed 's/G//; s/Ti//; s/Mi//')
            free_disk_space=$(echo "$df_output" | awk '{print $4}' | sed 's/G//; s/Ti//; s/Mi//')
            used_disk=$(echo "$df_output" | awk '{print $3}' | sed 's/G//; s/Ti//; s/Mi//')
        fi
        
        # Calculate used disk space percentage - handle different units
        # Use df's formula: used / (used + available) to match df -h output
        if [[ "$total_disk" =~ ^[0-9]+$ && "$used_disk" =~ ^[0-9]+$ && "$free_disk_space" =~ ^[0-9]+$ ]]; then
            used_disk_percent=$(echo "scale=1; $used_disk * 100 / ($used_disk + $free_disk_space)" | bc -l 2>/dev/null || echo "0")
            total_disk_gb=$total_disk
        else
            used_disk_percent="0"
            total_disk_gb="0"
        fi
    else
        free_disk_space="unknown"
        used_disk_percent="0"
        total_disk_gb="0"
    fi
    
    # Get memory usage - cross-platform
    if command -v free >/dev/null 2>&1; then
        # Linux (Ubuntu/AWS) - use free command
        total_mem=$(free -m | awk 'NR==2{print $2}')
        used_mem=$(free -m | awk 'NR==2{print $3}')
        if [[ -n "$total_mem" && "$total_mem" -gt 0 ]]; then
            mem_usage_percent=$(echo "scale=1; $used_mem * 100 / $total_mem" | bc -l 2>/dev/null || echo "0")
            # Convert MB to GB for display
            total_mem_gb=$(echo "scale=1; $total_mem / 1024" | bc -l 2>/dev/null || echo "0")
        else
            mem_usage_percent="0"
            total_mem_gb="0"
        fi
    elif command -v vm_stat >/dev/null 2>&1; then
        # macOS - improved memory calculation
        vm_stat_output=$(vm_stat)
        total_mem=$(sysctl -n hw.memsize 2>/dev/null | awk '{print $1 / 1024 / 1024 / 1024}')
        if [[ -z "$total_mem" || "$total_mem" = "0" ]]; then
            total_mem=0
            total_mem_gb=0
            mem_usage_percent="0"
        else
            total_mem_gb=$total_mem
            
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
        fi
    else
        # Fallback for other systems
        mem_usage_percent="0"
        total_mem_gb="0"
    fi
    
    # Get CPU cores count - cross-platform
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "1")
    else
        # Linux (Ubuntu/AWS) - try multiple methods
        if command -v nproc >/dev/null 2>&1; then
            cpu_cores=$(nproc 2>/dev/null || echo "1")
        elif [ -f /proc/cpuinfo ]; then
            cpu_cores=$(grep -c processor /proc/cpuinfo 2>/dev/null || echo "1")
        elif command -v lscpu >/dev/null 2>&1; then
            cpu_cores=$(lscpu | grep "CPU(s):" | awk '{print $2}' 2>/dev/null || echo "1")
        else
            cpu_cores="1"
        fi
    fi
    
    # Ensure cpu_cores is a valid number
    if [[ ! "$cpu_cores" =~ ^[0-9]+$ ]] || [[ "$cpu_cores" -lt 1 ]]; then
        cpu_cores="1"
    fi
    
    # Get CPU speed - cross-platform
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS - use sysctl for CPU frequency
        cpu_speed_raw=$(sysctl -n hw.cpufrequency 2>/dev/null || echo "0")
        if [[ "$cpu_speed_raw" =~ ^[0-9]+$ ]] && [[ "$cpu_speed_raw" -gt 0 ]]; then
            # Convert Hz to GHz
            cpu_speed=$(echo "scale=2; $cpu_speed_raw / 1000000000" | bc -l 2>/dev/null || echo "0")
            cpu_speed="${cpu_speed} GHz"
        else
            # Try alternative method for Apple Silicon
            cpu_speed_raw=$(sysctl -n hw.cpufrequency_max 2>/dev/null || echo "0")
            if [[ "$cpu_speed_raw" =~ ^[0-9]+$ ]] && [[ "$cpu_speed_raw" -gt 0 ]]; then
                cpu_speed=$(echo "scale=2; $cpu_speed_raw / 1000000000" | bc -l 2>/dev/null || echo "0")
                cpu_speed="${cpu_speed} GHz"
            else
                # For Apple Silicon, get the processor model name
                cpu_name=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")
                if [[ "$cpu_name" == *"Apple"* ]]; then
                    # Extract the processor model (M1, M2, M3, etc.) with variant
                    if [[ "$cpu_name" =~ (M[0-9]+[[:space:]]*[A-Za-z]*) ]]; then
                        cpu_speed="${BASH_REMATCH[1]}"
                    elif [[ "$cpu_name" =~ (A[0-9]+[[:space:]]*[A-Za-z]*) ]]; then
                        cpu_speed="${BASH_REMATCH[1]}"
                    else
                        cpu_speed="Apple Silicon"
                    fi
                else
                    cpu_speed="unknown"
                fi
            fi
        fi
    else
        # Linux - try multiple methods
        if command -v lscpu >/dev/null 2>&1; then
            # Use lscpu for CPU frequency
            cpu_speed_raw=$(lscpu | grep "CPU MHz:" | awk '{print $3}' 2>/dev/null || echo "0")
            if [[ "$cpu_speed_raw" =~ ^[0-9]*\.?[0-9]+$ ]] && [[ $(echo "$cpu_speed_raw > 0" | bc -l 2>/dev/null || echo "0") -eq 1 ]]; then
                # Convert MHz to GHz
                cpu_speed=$(echo "scale=2; $cpu_speed_raw / 1000" | bc -l 2>/dev/null || echo "0")
                cpu_speed="${cpu_speed} GHz"
            else
                # Try max frequency
                cpu_speed_raw=$(lscpu | grep "CPU max MHz:" | awk '{print $4}' 2>/dev/null || echo "0")
                if [[ "$cpu_speed_raw" =~ ^[0-9]*\.?[0-9]+$ ]] && [[ $(echo "$cpu_speed_raw > 0" | bc -l 2>/dev/null || echo "0") -eq 1 ]]; then
                    cpu_speed=$(echo "scale=2; $cpu_speed_raw / 1000" | bc -l 2>/dev/null || echo "0")
                    cpu_speed="${cpu_speed} GHz"
                else
                    cpu_speed="unknown"
                fi
            fi
        elif [ -f /proc/cpuinfo ]; then
            # Use /proc/cpuinfo for CPU frequency
            cpu_speed_raw=$(grep "cpu MHz" /proc/cpuinfo | head -1 | awk '{print $4}' 2>/dev/null || echo "0")
            if [[ "$cpu_speed_raw" =~ ^[0-9]*\.?[0-9]+$ ]] && [[ $(echo "$cpu_speed_raw > 0" | bc -l 2>/dev/null || echo "0") -eq 1 ]]; then
                # Convert MHz to GHz
                cpu_speed=$(echo "scale=2; $cpu_speed_raw / 1000" | bc -l 2>/dev/null || echo "0")
                cpu_speed="${cpu_speed} GHz"
            else
                cpu_speed="unknown"
            fi
        else
            cpu_speed="unknown"
        fi
    fi
    
    # Check if bc is available for calculations
    if ! command -v bc >/dev/null 2>&1; then
        echo "Warning: bc not found. Some calculations may be simplified."
        echo "Installation:"
        echo "  macOS: brew install bc"
        echo "  Ubuntu/Debian: sudo apt-get install bc"
        echo "  Amazon Linux: sudo yum install bc"
    fi
    
    # Get load averages (1, 5, 15 minute averages) for detailed breakdown
    # Handle both formats: "load average:" and "load averages:"
    load_avg_1=$(uptime | sed -E 's/.*load average[s]?: //' | awk '{print $1}' | sed 's/,//')
    load_avg_5=$(uptime | sed -E 's/.*load average[s]?: //' | awk '{print $2}' | sed 's/,//')
    load_avg_15=$(uptime | sed -E 's/.*load average[s]?: //' | awk '{print $3}' | sed 's/,//')
    
    # Calculate load average percentages (load per core)
    load_1_percent=$(echo "scale=1; $load_avg_1 * 100 / $cpu_cores" | bc -l 2>/dev/null || echo "0")
    load_5_percent=$(echo "scale=1; $load_avg_5 * 100 / $cpu_cores" | bc -l 2>/dev/null || echo "0")
    load_15_percent=$(echo "scale=1; $load_avg_15 * 100 / $cpu_cores" | bc -l 2>/dev/null || echo "0")
    
    load_averages="${load_1_percent}% (1m), ${load_5_percent}% (5m), ${load_15_percent}% (15m)"
    
    # Get CPU breakdown for detailed analysis (cross-platform)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS - use top command to get detailed CPU usage
        cpu_info=$(top -l 1 | grep "CPU usage")
        if [[ -n "$cpu_info" ]]; then
            # Extract user, system, and idle percentages
            cpu_user=$(echo "$cpu_info" | awk '{print $3}' | sed 's/%//')
            cpu_sys=$(echo "$cpu_info" | awk '{print $5}' | sed 's/%//')
            cpu_idle=$(echo "$cpu_info" | awk '{print $7}' | sed 's/%//')
            cpu_breakdown="${cpu_user}% user, ${cpu_sys}% sys, ${cpu_idle}% idle"
        else
            cpu_breakdown="unknown"
        fi
    else
        # Linux - try multiple methods for current CPU usage breakdown
        if command -v mpstat >/dev/null 2>&1; then
            cpu_load_raw=$(mpstat 1 1 | awk 'END {print 100-$NF}' | sed 's/,/./')
            if [[ "$cpu_load_raw" =~ ^[0-9]*\.?[0-9]+$ ]]; then
                cpu_breakdown="mpstat: ${cpu_load_raw}%"
            else
                cpu_breakdown="unknown"
            fi
        elif command -v top >/dev/null 2>&1; then
            cpu_load_raw=$(top -bn1 | grep -E "Cpu\(s\)|%Cpu" | head -1 | awk '{print $2}' | sed 's/%us,//; s/,/./')
            if [[ "$cpu_load_raw" =~ ^[0-9]*\.?[0-9]+$ ]]; then
                cpu_breakdown="top: ${cpu_load_raw}%"
            else
                cpu_breakdown="unknown"
            fi
        else
            cpu_breakdown="unknown"
        fi
    fi
    
    # Use 15-minute load average as the primary CPU load metric
    # This gives a better picture of system load over time rather than instantaneous usage
    cpu_load_percent=$load_15_percent
    
    # Ensure CPU usage is a valid number (load averages can exceed 100% under heavy load)
    if [[ ! "$cpu_load_percent" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        cpu_load_percent="0"
    fi
    
    cpu_load="${cpu_load_percent}%"
    
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
    
    # Scan for exceptions in log file
    exception_count=0
    log_file="$HOME/logs/node.log"
    if [ -f "$log_file" ]; then
        # Count actual exceptions by looking for error messages that precede stack traces
        # Each exception starts with an error message, followed by stack trace lines
        exception_count=$(grep -B1 "^[[:space:]]\+at " "$log_file" | grep -v "^[[:space:]]\+at " | grep -v "^--$" | grep -E "Exception|Error|MEMETIC" | wc -l 2>/dev/null | tr -d ' \n' || echo "0")
        
        # If we found exceptions, get more details
        if [ "$exception_count" -gt 0 ]; then
            # Count unique error types by looking at the line before each stack trace
            # Extract just the error type (Exception, Error, MEMETIC, etc.)
            error_types=$(grep -B1 "^[[:space:]]\+at " "$log_file" | grep -v "^[[:space:]]\+at " | grep -v "^--$" | grep -o -E "(Exception|Error|MEMETIC)" | sort | uniq -c | tr '\n' ' ' | sed 's/ *$//' 2>/dev/null | tr -d '\n' || echo "")
            exception_summary="${exception_count} exceptions found"
            if [ -n "$error_types" ]; then
                exception_summary="${exception_summary} (${error_types})"
            fi
        else
            exception_summary="No exceptions found"
        fi
    else
        exception_summary="No log file found"
    fi
    
    # Ensure uptime_sec is a number
    if [[ ! "$uptime_sec" =~ ^[0-9]+$ ]]; then
        uptime_sec=0
    fi
    
    echo "{\"uptime\": $uptime_sec, \"free_disk_space\": \"$free_disk_space\", \"used_disk_percent\": \"$used_disk_percent\", \"total_disk_gb\": \"$total_disk_gb\", \"mem_usage_percent\": \"$mem_usage_percent\", \"total_mem_gb\": \"$total_mem_gb\", \"cpu_load\": \"$cpu_load\", \"cpu_cores\": \"$cpu_cores\", \"cpu_model\": \"$cpu_speed\", \"cpu_breakdown\": \"$cpu_breakdown\", \"load_averages\": \"$load_averages\", \"timezone\": \"$timezone\", \"os_info\": \"$os_info\", \"os_version\": \"$os_version\", \"network_status\": \"$network_status\", \"exception_count\": $exception_count, \"exception_summary\": \"$exception_summary\"}"
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
           '.[$host] = ((.[$host] // {}) + $info | .heart_beat_ts = ($ts | tonumber))' \
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
        # Cross-platform date formatting
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS - use -r flag
            commit_date=$(date -r $CURRENT_TS 2>/dev/null || date)
        else
            # Linux - use @timestamp format
            commit_date=$(date -d "@$CURRENT_TS" 2>/dev/null || date)
        fi
        git commit -m "Update health status for $HOSTNAME at $commit_date" 2>/dev/null || true
        
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