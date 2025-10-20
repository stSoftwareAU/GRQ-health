#!/bin/bash

# Health monitoring script for GRQ-health
# This script checks system health and updates docs/index.json
# Compatible with macOS, Ubuntu, and AWS Linux
# Automatically skips execution on AWS instances to avoid dead entries
# All AWS instances in this context are spot/temporary and would create dead entries
# Fixed machine type detection to handle corrupted output and encoding issues

set -e

BASE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

cd "${BASE_DIR}"

# Configuration
JSON_FILE="docs/index.json"
HEARTBEAT_THRESHOLD_HOURS=6
VERSION="1.0.39"

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
            echo ""
            echo "Note: This script automatically skips execution on spot instances"
            echo "      to avoid creating dead entries in the health dashboard."
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

# Function to detect if this is an AWS instance (all AWS instances are spot/temporary)
is_aws_instance() {
    # Check if we can reach AWS metadata service (only works on AWS EC2)
    if command -v curl >/dev/null 2>&1; then
        if curl -s --max-time 2 http://169.254.169.254/latest/meta-data/instance-id >/dev/null 2>&1; then
            return 0  # We're on an AWS instance
        fi
    fi
    
    return 1  # Not an AWS instance
}

# Check if this is an AWS instance and exit if so
# All AWS instances in this context are spot/temporary and should be skipped
# This prevents creating dead entries in the health dashboard from ephemeral instances
if is_aws_instance; then
    echo "Skipping health monitoring - this is an AWS instance (spot/temporary)"
    exit 0
fi

# Function to get system information
get_system_info() {
    # Ensure /usr/sbin is in PATH for macOS (needed for sysctl)
    if [[ "$OSTYPE" == "darwin"* ]] && [[ ":$PATH:" != *":/usr/sbin:"* ]]; then
        export PATH="/usr/sbin:$PATH"
        echo "DEBUG: Added /usr/sbin to PATH for sysctl access" >> "$HOME/logs/node.log" 2>/dev/null || true
    fi
    
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
            # Linux/AWS - find the largest available storage
            # First try to find the main data partition (usually the largest)
            largest_fs=""
            largest_size=0
            
            # Get all mounted filesystems and find the largest one
            while IFS= read -r line; do
                if [[ "$line" =~ ^/dev/ ]]; then
                    # Extract size and convert to GB for comparison
                    size_str=$(echo "$line" | awk '{print $2}')
                    size_gb=0
                    
                    # Convert different units to GB for comparison
                    if [[ "$size_str" =~ ([0-9]+)T ]]; then
                        size_gb=$((${BASH_REMATCH[1]} * 1024))
                    elif [[ "$size_str" =~ ([0-9]+)G ]]; then
                        size_gb=${BASH_REMATCH[1]}
                    elif [[ "$size_str" =~ ([0-9]+)M ]]; then
                        size_gb=$((${BASH_REMATCH[1]} / 1024))
                    fi
                    
                    # Skip very small filesystems (boot, efi, tmpfs, etc.)
                    if [[ $size_gb -gt 10 && $size_gb -gt $largest_size ]]; then
                        largest_fs="$line"
                        largest_size=$size_gb
                    fi
                fi
            done < <(df -h | grep -E '^/dev/')
            
            # Use the largest filesystem found, or fallback to current directory
            if [[ -n "$largest_fs" ]]; then
                df_output="$largest_fs"
                echo "DEBUG: Using largest filesystem: $largest_fs" >> "$HOME/logs/node.log" 2>/dev/null || true
            else
                # Fallback to current directory
                current_dir=$(pwd)
                df_output=$(df -h "$current_dir" | awk 'NR==2')
                echo "DEBUG: Fallback to current directory: $current_dir" >> "$HOME/logs/node.log" 2>/dev/null || true
            fi
            
            # Linux/AWS - handle G suffix and other variations
            total_disk=$(echo "$df_output" | awk '{print $2}' | sed 's/G//; s/Ti//; s/Mi//')
            free_disk_space=$(echo "$df_output" | awk '{print $4}' | sed 's/G//; s/Ti//; s/Mi//')
            used_disk=$(echo "$df_output" | awk '{print $3}' | sed 's/G//; s/Ti//; s/Mi//')
            
            echo "DEBUG: Disk detection - total: $total_disk, free: $free_disk_space, used: $used_disk" >> "$HOME/logs/node.log" 2>/dev/null || true
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
    
    # Get machine type and CPU speed - cross-platform
    machine_type=""
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS - get machine type using system_profiler with multiple fallbacks
        machine_type=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Model Name:" | sed 's/.*Model Name: //' | tr -d '\n' || echo "")
        echo "DEBUG: system_profiler result: '$machine_type'" >> "$HOME/logs/node.log" 2>/dev/null || true
        
        # If that fails, try alternative methods
        if [[ -z "$machine_type" ]]; then
            # Try getting the model identifier and map it (macOS only)
            model_id=""
            if command -v sysctl >/dev/null 2>&1; then
                model_id=$(sysctl -n hw.model 2>/dev/null || echo "")
                echo "DEBUG: sysctl hw.model result: '$model_id'" >> "$HOME/logs/node.log" 2>/dev/null || true
            else
                echo "DEBUG: sysctl command not found in PATH" >> "$HOME/logs/node.log" 2>/dev/null || true
            fi
            if [[ -n "$model_id" ]]; then
                case "$model_id" in
                    "Mac14,2") machine_type="MacBook Pro (M2 Pro)" ;;
                    "Mac14,3") machine_type="MacBook Pro (M2 Max)" ;;
                    "Mac14,5") machine_type="Mac mini (M2)" ;;
                    "Mac14,6") machine_type="Mac mini (M2 Pro)" ;;
                    "Mac14,7") machine_type="MacBook Air (M2)" ;;
                    "Mac14,8") machine_type="MacBook Air (M2)" ;;
                    "Mac14,9") machine_type="MacBook Pro (M2)" ;;
                    "Mac14,10") machine_type="MacBook Pro (M2)" ;;
                    "Mac14,11") machine_type="MacBook Pro (M2 Pro)" ;;
                    "Mac14,12") machine_type="MacBook Pro (M2 Max)" ;;
                    "Mac14,13") machine_type="Mac Studio (M2 Max)" ;;
                    "Mac14,14") machine_type="Mac Studio (M2 Ultra)" ;;
                    "Mac14,15") machine_type="Mac Pro (M2 Ultra)" ;;
                    "Mac14,16") machine_type="MacBook Pro (M3)" ;;
                    "Mac14,17") machine_type="MacBook Pro (M3 Pro)" ;;
                    "Mac14,18") machine_type="MacBook Pro (M3 Max)" ;;
                    "Mac14,19") machine_type="MacBook Air (M3)" ;;
                    "Mac14,20") machine_type="MacBook Air (M3)" ;;
                    "Mac14,21") machine_type="Mac mini (M3)" ;;
                    "Mac14,22") machine_type="Mac mini (M3 Pro)" ;;
                    "Mac14,23") machine_type="MacBook Pro (M3)" ;;
                    "Mac14,24") machine_type="MacBook Pro (M3 Pro)" ;;
                    "Mac14,25") machine_type="MacBook Pro (M3 Max)" ;;
                    "Mac14,26") machine_type="MacBook Pro (M3 Max)" ;;
                    "Mac14,27") machine_type="MacBook Air (M3)" ;;
                    "Mac14,28") machine_type="MacBook Air (M3)" ;;
                    "Mac14,29") machine_type="Mac mini (M3)" ;;
                    "Mac14,30") machine_type="Mac mini (M3 Pro)" ;;
                    "Mac14,31") machine_type="Mac Studio (M3 Max)" ;;
                    "Mac14,32") machine_type="Mac Studio (M3 Ultra)" ;;
                    "Mac15,1") machine_type="MacBook Air (M3)" ;;
                    "Mac15,2") machine_type="MacBook Air (M3)" ;;
                    "Mac15,3") machine_type="MacBook Pro (M3)" ;;
                    "Mac15,4") machine_type="MacBook Pro (M3 Pro)" ;;
                    "Mac15,5") machine_type="MacBook Pro (M3 Max)" ;;
                    "Mac15,6") machine_type="MacBook Pro (M3 Max)" ;;
                    "Mac15,7") machine_type="Mac mini (M3)" ;;
                    "Mac15,8") machine_type="Mac mini (M3 Pro)" ;;
                    "Mac15,9") machine_type="Mac Studio (M3 Max)" ;;
                    "Mac15,10") machine_type="Mac Studio (M3 Ultra)" ;;
                    "Mac15,11") machine_type="Mac Pro (M3 Ultra)" ;;
                    "Mac15,12") machine_type="Mac Pro (M3 Ultra)" ;;
                    *) machine_type="Mac ($model_id)" ;;
                esac
            fi
        fi
        
        # If still no machine type, try one more fallback
        if [[ -z "$machine_type" ]]; then
            # Try getting the marketing name
            machine_type=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Marketing Name:" | sed 's/.*Marketing Name: //' | tr -d '\n' || echo "")
        fi
    else
        # Linux/Ubuntu - try multiple methods to get machine type
        if [ -f /sys/class/dmi/id/product_name ]; then
            # Modern Linux systems with DMI
            machine_type=$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr -d '\n' | tr -cd '[:print:][:space:]' || echo "")
            echo "DEBUG: DMI product_name result: '$machine_type'" >> "$HOME/logs/node.log" 2>/dev/null || true
        elif [ -f /proc/device-tree/model ]; then
            # ARM-based systems (like Raspberry Pi)
            machine_type=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\n' | tr -cd '[:print:][:space:]' || echo "")
            echo "DEBUG: device-tree model result: '$machine_type'" >> "$HOME/logs/node.log" 2>/dev/null || true
        elif command -v dmidecode >/dev/null 2>&1; then
            # Use dmidecode if available
            machine_type=$(dmidecode -s system-product-name 2>/dev/null | tr -d '\n' | tr -cd '[:print:][:space:]' || echo "")
            echo "DEBUG: dmidecode result: '$machine_type'" >> "$HOME/logs/node.log" 2>/dev/null || true
        elif [ -f /etc/machine-info ]; then
            # Some systems store machine info here
            machine_type=$(grep "PRETTY_HOSTNAME" /etc/machine-info 2>/dev/null | sed 's/PRETTY_HOSTNAME=//' | tr -d '\n' | tr -cd '[:print:][:space:]' || echo "")
            echo "DEBUG: machine-info result: '$machine_type'" >> "$HOME/logs/node.log" 2>/dev/null || true
        else
            echo "DEBUG: No machine type detection methods available" >> "$HOME/logs/node.log" 2>/dev/null || true
        fi
        
        
        # Clean up the machine type string
        if [[ -n "$machine_type" ]]; then
            echo "DEBUG: Raw machine_type before cleanup: '$machine_type'" >> "$HOME/logs/node.log" 2>/dev/null || true
            # Remove common prefixes and clean up
            machine_type=$(echo "$machine_type" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed 's/^Dell Inc\. //; s/^HP //; s/^Lenovo //; s/^ASUSTeK //; s/^GIGABYTE //; s/^MSI //')
            echo "DEBUG: machine_type after prefix removal: '$machine_type'" >> "$HOME/logs/node.log" 2>/dev/null || true
            
            # Validate and sanitize the machine type string
            # Remove any non-printable characters and ensure it's a valid string
            machine_type=$(echo "$machine_type" | tr -cd '[:print:][:space:]' | sed 's/[[:space:]]*$//')
            echo "DEBUG: machine_type after sanitization: '$machine_type'" >> "$HOME/logs/node.log" 2>/dev/null || true
            
            # If the result is empty, contains only whitespace, or is corrupted, set a fallback
            # Allow common characters in machine names: alphanumeric, spaces, hyphens, parentheses, periods, underscores, colons
            if [[ -z "$machine_type" ]] || [[ "$machine_type" =~ ^[[:space:]]*$ ]] || [[ "$machine_type" =~ [^[:alnum:][:space:]-()._:] ]]; then
                # Log debug info before setting to Unknown
                echo "DEBUG: Machine type validation failed, setting to Unknown" >> "$HOME/logs/node.log" 2>/dev/null || true
                echo "DEBUG: machine_type='$machine_type'" >> "$HOME/logs/node.log" 2>/dev/null || true
                echo "DEBUG: OSTYPE='$OSTYPE'" >> "$HOME/logs/node.log" 2>/dev/null || true
                machine_type="Unknown"
            fi
        fi
        
        # If no machine type was detected, use uname as fallback
        if [[ -z "$machine_type" ]]; then
            uname_output=$(uname -a 2>/dev/null || echo "")
            if [[ -n "$uname_output" ]]; then
                # Extract useful information from uname -a
                # Format: Linux hostname kernel version architecture
                hostname_part=$(echo "$uname_output" | awk '{print $2}')
                arch_part=$(echo "$uname_output" | awk '{print $(NF-1)}')
                kernel_part=$(echo "$uname_output" | awk '{print $3}' | cut -d'-' -f1)
                
                # Create a descriptive machine type from uname info
                machine_type="Linux ($hostname_part, $arch_part, kernel $kernel_part)"
                echo "DEBUG: Using uname -a fallback: '$machine_type'" >> "$HOME/logs/node.log" 2>/dev/null || true
            else
                # Log debug info before setting to Unknown
                echo "DEBUG: No machine type detected, setting to Unknown" >> "$HOME/logs/node.log" 2>/dev/null || true
                echo "DEBUG: OSTYPE='$OSTYPE'" >> "$HOME/logs/node.log" 2>/dev/null || true
                machine_type="Unknown"
            fi
        fi
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
                    # Extract the processor model (M1, M2, M3, etc.) with variant using grep
                    processor_model=$(echo "$cpu_name" | grep -o "M[0-9]\+[[:space:]]*[A-Za-z]*" | head -1)
                    if [[ -n "$processor_model" ]]; then
                        cpu_speed="$processor_model"
                    else
                        # Try A-series processors
                        processor_model=$(echo "$cpu_name" | grep -o "A[0-9]\+[[:space:]]*[A-Za-z]*" | head -1)
                        if [[ -n "$processor_model" ]]; then
                            cpu_speed="$processor_model"
                        else
                            # Log debug info before falling back to generic "Apple Silicon"
                            echo "DEBUG: Apple Silicon detected but processor model extraction failed" >> "$HOME/logs/node.log" 2>/dev/null || true
                            echo "DEBUG: cpu_name='$cpu_name'" >> "$HOME/logs/node.log" 2>/dev/null || true
                            echo "DEBUG: grep M-series result: '$(echo "$cpu_name" | grep -o "M[0-9]\+[[:space:]]*[A-Za-z]*" | head -1)'" >> "$HOME/logs/node.log" 2>/dev/null || true
                            echo "DEBUG: grep A-series result: '$(echo "$cpu_name" | grep -o "A[0-9]\+[[:space:]]*[A-Za-z]*" | head -1)'" >> "$HOME/logs/node.log" 2>/dev/null || true
                            cpu_speed="Apple Silicon"
                        fi
                    fi
                else
                    # Log debug info before setting to unknown
                    echo "DEBUG: Non-Apple processor detected, setting cpu_speed to unknown" >> "$HOME/logs/node.log" 2>/dev/null || true
                    echo "DEBUG: cpu_name='$cpu_name'" >> "$HOME/logs/node.log" 2>/dev/null || true
                    echo "DEBUG: OSTYPE='$OSTYPE'" >> "$HOME/logs/node.log" 2>/dev/null || true
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
                    # Log debug info before setting to unknown
                    echo "DEBUG: Linux CPU detection failed - lscpu max frequency not available" >> "$HOME/logs/node.log" 2>/dev/null || true
                    echo "DEBUG: cpu_speed_raw='$cpu_speed_raw'" >> "$HOME/logs/node.log" 2>/dev/null || true
                    echo "DEBUG: OSTYPE='$OSTYPE'" >> "$HOME/logs/node.log" 2>/dev/null || true
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
                # Log debug info before setting to unknown
                echo "DEBUG: Linux CPU detection failed - /proc/cpuinfo frequency not available" >> "$HOME/logs/node.log" 2>/dev/null || true
                echo "DEBUG: cpu_speed_raw='$cpu_speed_raw'" >> "$HOME/logs/node.log" 2>/dev/null || true
                echo "DEBUG: OSTYPE='$OSTYPE'" >> "$HOME/logs/node.log" 2>/dev/null || true
                cpu_speed="unknown"
            fi
        else
            # Log debug info before setting to unknown
            echo "DEBUG: Linux CPU detection failed - no lscpu or /proc/cpuinfo available" >> "$HOME/logs/node.log" 2>/dev/null || true
            echo "DEBUG: OSTYPE='$OSTYPE'" >> "$HOME/logs/node.log" 2>/dev/null || true
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
            # Log debug info before setting cpu_breakdown to unknown
            echo "DEBUG: macOS CPU breakdown detection failed - no CPU usage info found" >> "$HOME/logs/node.log" 2>/dev/null || true
            echo "DEBUG: cpu_info='$cpu_info'" >> "$HOME/logs/node.log" 2>/dev/null || true
            echo "DEBUG: OSTYPE='$OSTYPE'" >> "$HOME/logs/node.log" 2>/dev/null || true
            cpu_breakdown="unknown"
        fi
    else
        # Linux - try multiple methods for current CPU usage breakdown
        if command -v mpstat >/dev/null 2>&1; then
            cpu_load_raw=$(mpstat 1 1 | awk 'END {print 100-$NF}' | sed 's/,/./')
            if [[ "$cpu_load_raw" =~ ^[0-9]*\.?[0-9]+$ ]]; then
                cpu_breakdown="mpstat: ${cpu_load_raw}%"
            else
                # Log debug info before setting cpu_breakdown to unknown
                echo "DEBUG: Linux CPU breakdown detection failed - mpstat result invalid" >> "$HOME/logs/node.log" 2>/dev/null || true
                echo "DEBUG: cpu_load_raw='$cpu_load_raw'" >> "$HOME/logs/node.log" 2>/dev/null || true
                echo "DEBUG: OSTYPE='$OSTYPE'" >> "$HOME/logs/node.log" 2>/dev/null || true
                cpu_breakdown="unknown"
            fi
        elif command -v top >/dev/null 2>&1; then
            cpu_load_raw=$(top -bn1 | grep -E "Cpu\(s\)|%Cpu" | head -1 | awk '{print $2}' | sed 's/%us,//; s/,/./')
            if [[ "$cpu_load_raw" =~ ^[0-9]*\.?[0-9]+$ ]]; then
                cpu_breakdown="top: ${cpu_load_raw}%"
            else
                # Log debug info before setting cpu_breakdown to unknown
                echo "DEBUG: Linux CPU breakdown detection failed - top result invalid" >> "$HOME/logs/node.log" 2>/dev/null || true
                echo "DEBUG: cpu_load_raw='$cpu_load_raw'" >> "$HOME/logs/node.log" 2>/dev/null || true
                echo "DEBUG: OSTYPE='$OSTYPE'" >> "$HOME/logs/node.log" 2>/dev/null || true
                cpu_breakdown="unknown"
            fi
        else
            # Log debug info before setting cpu_breakdown to unknown
            echo "DEBUG: Linux CPU breakdown detection failed - no mpstat or top available" >> "$HOME/logs/node.log" 2>/dev/null || true
            echo "DEBUG: OSTYPE='$OSTYPE'" >> "$HOME/logs/node.log" 2>/dev/null || true
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
            # Modern Linux systems - source the file and get proper version info
            source /etc/os-release
            os_info="$NAME"
            # Use VERSION_ID for version number, fallback to VERSION for descriptive version
            if [ -n "$VERSION_ID" ]; then
                os_version="$VERSION_ID"
            elif [ -n "$VERSION" ]; then
                os_version="$VERSION"
            else
                os_version="unknown"
            fi
        elif [ -f /etc/lsb-release ]; then
            # Ubuntu/Debian
            source /etc/lsb-release
            os_info="$DISTRIB_ID"
            os_version="$DISTRIB_RELEASE"
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
    
    # Get network connectivity and IP addresses
    network_status="unknown"
    ip_addresses=""
    
    if command -v ping >/dev/null 2>&1; then
        if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
            network_status="connected"
            
            # Get IP addresses for different interfaces
            if [[ "$OSTYPE" == "darwin"* ]]; then
                # macOS: use ifconfig to get IP addresses
                wifi_ip=$(ifconfig en0 2>/dev/null | grep "inet " | awk '{print $2}' | head -1)
                ethernet_ip=$(ifconfig en1 2>/dev/null | grep "inet " | awk '{print $2}' | head -1)
                
                # Also check for other common interface names
                if [[ -z "$wifi_ip" ]]; then
                    wifi_ip=$(ifconfig en2 2>/dev/null | grep "inet " | awk '{print $2}' | head -1)
                fi
                if [[ -z "$ethernet_ip" ]]; then
                    ethernet_ip=$(ifconfig en3 2>/dev/null | grep "inet " | awk '{print $2}' | head -1)
                fi
                
                # Build IP address string
                if [[ -n "$wifi_ip" && -n "$ethernet_ip" ]]; then
                    ip_addresses="WiFi: $wifi_ip, Eth: $ethernet_ip"
                elif [[ -n "$wifi_ip" ]]; then
                    ip_addresses="WiFi: $wifi_ip"
                elif [[ -n "$ethernet_ip" ]]; then
                    ip_addresses="Eth: $ethernet_ip"
                fi
            else
                # Linux: use ip command or ifconfig
                if command -v ip >/dev/null 2>&1; then
                    # Modern Linux with ip command
                    wifi_ip=$(ip addr show 2>/dev/null | grep -E "inet .* wlan|inet .* wifi" | awk '{print $2}' | cut -d'/' -f1 | head -1)
                    ethernet_ip=$(ip addr show 2>/dev/null | grep -E "inet .* eth|inet .* enp|inet .* ens" | awk '{print $2}' | cut -d'/' -f1 | head -1)
                    
                    # If no specific interface found, get any non-loopback IP
                    if [[ -z "$wifi_ip" && -z "$ethernet_ip" ]]; then
                        all_ips=$(ip addr show 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | cut -d'/' -f1 | tr '\n' ' ' | sed 's/ *$//')
                        if [[ -n "$all_ips" ]]; then
                            ip_addresses="$all_ips"
                        fi
                    else
                        # Build IP address string
                        if [[ -n "$wifi_ip" && -n "$ethernet_ip" ]]; then
                            ip_addresses="WiFi: $wifi_ip, Eth: $ethernet_ip"
                        elif [[ -n "$wifi_ip" ]]; then
                            ip_addresses="WiFi: $wifi_ip"
                        elif [[ -n "$ethernet_ip" ]]; then
                            ip_addresses="Eth: $ethernet_ip"
                        fi
                    fi
                else
                    # Fallback to ifconfig for older Linux systems
                    wifi_ip=$(ifconfig 2>/dev/null | grep -E "inet .* wlan|inet .* wifi" | awk '{print $2}' | head -1)
                    ethernet_ip=$(ifconfig 2>/dev/null | grep -E "inet .* eth|inet .* enp|inet .* ens" | awk '{print $2}' | head -1)
                    
                    # Build IP address string
                    if [[ -n "$wifi_ip" && -n "$ethernet_ip" ]]; then
                        ip_addresses="WiFi: $wifi_ip, Eth: $ethernet_ip"
                    elif [[ -n "$wifi_ip" ]]; then
                        ip_addresses="WiFi: $wifi_ip"
                    elif [[ -n "$ethernet_ip" ]]; then
                        ip_addresses="Eth: $ethernet_ip"
                    fi
                fi
            fi
        else
            network_status="disconnected"
        fi
    fi
    
    # Scan for exceptions in log file
    scan_log_errors
    
    # Check GRQ environment configuration
    config_warning=""
    ENV_FILE="$BASE_DIR/../GRQ/.env"
    if [ -f "$ENV_FILE" ]; then
        # Check for presence of at least one required variable
        if ! grep -Eq '^[[:space:]]*(PRIMARY_READ_URL|TRAINING_WRITE_URL)[[:space:]]*=' "$ENV_FILE"; then
            config_warning="Missing PRIMARY_READ_URL or TRAINING_WRITE_URL in ../GRQ/.env"
        fi
    else
        config_warning="Missing ../GRQ/.env"
    fi
    
    # Ensure uptime_sec is a number
    if [[ ! "$uptime_sec" =~ ^[0-9]+$ ]]; then
        uptime_sec=0
    fi
    
    # Final validation of machine_type to prevent corrupted output
    if [[ -z "$machine_type" ]] || [[ "$machine_type" =~ [^[:print:]] ]] || [[ "$machine_type" =~ ^[[:space:]]*$ ]]; then
        # Log debug info before final fallback to Unknown
        echo "DEBUG: Final machine type validation failed, setting to Unknown" >> "$HOME/logs/node.log" 2>/dev/null || true
        echo "DEBUG: machine_type='$machine_type'" >> "$HOME/logs/node.log" 2>/dev/null || true
        echo "DEBUG: OSTYPE='$OSTYPE'" >> "$HOME/logs/node.log" 2>/dev/null || true
        machine_type="Unknown"
    fi
    
    # Escape JSON strings to prevent parsing errors
    escape_json() {
        echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g; s/\n/\\n/g'
    }
    
    # Escape all string variables that might contain special characters
    free_disk_space_escaped=$(escape_json "$free_disk_space")
    used_disk_percent_escaped=$(escape_json "$used_disk_percent")
    total_disk_gb_escaped=$(escape_json "$total_disk_gb")
    mem_usage_percent_escaped=$(escape_json "$mem_usage_percent")
    total_mem_gb_escaped=$(escape_json "$total_mem_gb")
    cpu_load_escaped=$(escape_json "$cpu_load")
    cpu_cores_escaped=$(escape_json "$cpu_cores")
    cpu_speed_escaped=$(escape_json "$cpu_speed")
    machine_type_escaped=$(escape_json "$machine_type")
    cpu_breakdown_escaped=$(escape_json "$cpu_breakdown")
    load_averages_escaped=$(escape_json "$load_averages")
    timezone_escaped=$(escape_json "$timezone")
    os_info_escaped=$(escape_json "$os_info")
    os_version_escaped=$(escape_json "$os_version")
    network_status_escaped=$(escape_json "$network_status")
    ip_addresses_escaped=$(escape_json "$ip_addresses")
    exception_summary_escaped=$(escape_json "$exception_summary")
    config_warning_escaped=$(escape_json "$config_warning")
    
    echo "{\"uptime\": $uptime_sec, \"free_disk_space\": \"$free_disk_space_escaped\", \"used_disk_percent\": \"$used_disk_percent_escaped\", \"total_disk_gb\": \"$total_disk_gb_escaped\", \"mem_usage_percent\": \"$mem_usage_percent_escaped\", \"total_mem_gb\": \"$total_mem_gb_escaped\", \"cpu_load\": \"$cpu_load_escaped\", \"cpu_cores\": \"$cpu_cores_escaped\", \"cpu_model\": \"$cpu_speed_escaped\", \"machine_type\": \"$machine_type_escaped\", \"cpu_breakdown\": \"$cpu_breakdown_escaped\", \"load_averages\": \"$load_averages_escaped\", \"timezone\": \"$timezone_escaped\", \"os_info\": \"$os_info_escaped\", \"os_version\": \"$os_version_escaped\", \"network_status\": \"$network_status_escaped\", \"ip_addresses\": \"$ip_addresses_escaped\", \"exception_count\": $exception_count, \"exception_summary\": \"$exception_summary_escaped\", \"config_warning\": \"$config_warning_escaped\"}"
}

# Function to scan log file for errors and return count
scan_log_errors() {
    local log_file="$HOME/logs/node.log"
    # Initialize global variables
    exception_count=0
    exception_summary=""
    
    if [ -f "$log_file" ]; then
        # Count actual exceptions by looking for error messages that precede stack traces
        # Each exception starts with an error message, followed by stack trace lines
        local stack_trace_exceptions=$(grep -B1 "^[[:space:]]\+at " "$log_file" | grep -v "^[[:space:]]\+at " | grep -v "^--$" | grep -E "Exception|^Error:|MEMETIC" | wc -l 2>/dev/null | tr -d ' \n' || echo "0")
        
        # Count other critical errors that should be flagged
        # Missing commands/tools (excluding aws which is only expected on Macs)
        # Focus on missing script files which indicate configuration issues
        local missing_command_errors=$(grep -E "line [0-9]+: .*: No such file or directory" "$log_file" | wc -l 2>/dev/null | tr -d ' \n' || echo "0")
        
        # Count warning emoji issues (⚠️)
        local warning_emoji_errors=$(grep -c "⚠️" "$log_file" 2>/dev/null | tr -d ' \n' || echo "0")
        
        # Lock acquisition failures (removed - these are expected for daily tasks)
        local lock_failures=0
        
        # Permission/access errors
        local permission_errors=$(grep -E "Permission denied|access denied|EACCES" "$log_file" | wc -l 2>/dev/null | tr -d ' \n' || echo "0")
        
        # Network/connection errors (removed - too unreliable, causing false positives)
        local network_errors=0
        
        # Count all Deno crashes with C stack traces (includes out of memory, segfaults, etc.)
        local deno_crashes=$(grep -c "==== C stack trace" "$log_file" 2>/dev/null | tr -d ' \n' || echo "0")
        
        # Sum all error types
        exception_count=$((stack_trace_exceptions + missing_command_errors + warning_emoji_errors + lock_failures + permission_errors + network_errors + deno_crashes))
        
        # If we found exceptions, get more details
        if [ "$exception_count" -gt 0 ]; then
            # Build detailed error summary
            local error_details=""
            if [ "$stack_trace_exceptions" -gt 0 ]; then
                error_details="${error_details}${stack_trace_exceptions} stack traces"
            fi
            if [ "$missing_command_errors" -gt 0 ]; then
                if [ -n "$error_details" ]; then error_details="${error_details}, "; fi
                error_details="${error_details}${missing_command_errors} missing commands"
            fi
            if [ "$warning_emoji_errors" -gt 0 ]; then
                if [ -n "$error_details" ]; then error_details="${error_details}, "; fi
                error_details="${error_details}${warning_emoji_errors} warning issues"
            fi
            if [ "$lock_failures" -gt 0 ]; then
                if [ -n "$error_details" ]; then error_details="${error_details}, "; fi
                error_details="${error_details}${lock_failures} lock failures"
            fi
            if [ "$permission_errors" -gt 0 ]; then
                if [ -n "$error_details" ]; then error_details="${error_details}, "; fi
                error_details="${error_details}${permission_errors} permission errors"
            fi
            if [ "$deno_crashes" -gt 0 ]; then
                if [ -n "$error_details" ]; then error_details="${error_details}, "; fi
                error_details="${error_details}${deno_crashes} Deno crashes"
            fi
            exception_summary="${exception_count} errors found (${error_details})"
        else
            exception_summary="No errors found"
        fi
    else
        exception_summary="No log file found"
    fi
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
    
    # If the recorded script version doesn't match current VERSION, update immediately
    local recorded_version
    recorded_version=$(jq -r ".\"$HOSTNAME\".version // \"\"" "$JSON_FILE" 2>/dev/null || echo "")
    if [ "$recorded_version" != "$VERSION" ]; then
        echo "Version mismatch for $HOSTNAME (found '$recorded_version', current '$VERSION') - updating"
        return 0
    fi

    # If there are exceptions in the log, update regardless of heartbeat
    scan_log_errors
    if [ "$exception_count" -gt 0 ]; then
        echo "Exceptions detected ($exception_count) - updating regardless of last heartbeat time"
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
           --arg version "$VERSION" \
           --argjson info "$system_info" \
           '.[$host] = ((.[$host] // {}) + $info
             | .heart_beat_ts = ($ts | tonumber)
             | .version = $version)' \
           "$JSON_FILE" > "${JSON_FILE}.tmp2" && mv "${JSON_FILE}.tmp2" "$JSON_FILE"
    else
        # Create new file
        jq --arg host "$HOSTNAME" \
           --arg ts "$CURRENT_TS" \
           --arg version "$VERSION" \
           --argjson info "$system_info" \
           '{($host): ($info + {"heart_beat_ts": ($ts | tonumber), "version": $version})}' \
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
        git pull --rebase
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
