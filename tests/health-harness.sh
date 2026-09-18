#!/bin/bash
# Shared harness for the tests that drive run.sh's health-document writer
# (Issue #65 recovery, Issue #213 per-host documents).
#
# Both callers need the same thing: the real `update_json` (and the Issue #213
# helpers next to it) lifted out of run.sh and run against a stub
# `get_system_info`, so the assertions are made against the files the real code
# writes rather than against a copy of it.
#
# Usage:
#   RUN_SH="$SCRIPT_DIR/../run.sh"
#   source "$SCRIPT_DIR/health-harness.sh"
#   build_health_harness "$dir"                 # final call defaults to update_json
#   build_health_harness "$dir" 'host_slug "$HOSTNAME"'
#   run_health_harness "$dir" HOSTNAME=X CURRENT_TS=Y
#
# run_health_harness prints the harness output and returns its exit status; the
# status is also left in $LAST_HARNESS_STATUS for callers that do not capture
# the return value.

# Write a self-contained harness script into $1, ending with the call in $2
# (default: update_json).
build_health_harness() {
    local dir="$1"
    cat > "${dir}/test_harness.sh" << 'HARNESS_EOF'
#!/bin/bash
set -euo pipefail

# Minimal stubs for testing update_json in isolation
HOSTNAME="${HOSTNAME:-TEST-HOST}"
USER_KEY="${USER_KEY:-testuser}"
CURRENT_TS="${CURRENT_TS:-1700000000}"
VERSION="1.0.90"
USER_STALE_HOURS="${USER_STALE_HOURS:-24}"
JSON_FILE="${JSON_FILE:-docs/index.json}"
HOST_STATUS_DIR="${HOST_STATUS_DIR:-docs/host-status}"
HEALTH_STATE_DIR="${HEALTH_STATE_DIR:-.health-state}"

# Minimal get_system_info that returns valid JSON
get_system_info() {
    cat << 'SYSINFO'
{
    "uptime": 1000,
    "free_disk_space": "100",
    "disk_usage_percent": "20.0",
    "mem_usage_percent": "10.0",
    "cpu_load": "5.0%",
    "timezone": "AEST",
    "os_info": "macOS",
    "os_version": "15.0",
    "network_status": "connected",
    "total_mem_gb": "16",
    "cpu_cores": "8",
    "total_disk_gb": "500",
    "used_disk_percent": "20.0",
    "cpu_breakdown": "5% user, 3% sys, 92% idle",
    "load_averages": "5.0% (1m), 4.0% (5m), 3.0% (15m)",
    "cpu_model": "M4",
    "exception_count": 0,
    "exception_summary": "No errors found",
    "machine_type": "Mac mini",
    "ip_addresses": "WiFi: 10.0.0.1",
    "config_warning": ""
}
SYSINFO
}

HARNESS_EOF
    # Extract update_json and the Issue #213 helpers that sit beside it.
    sed -n '/^# Function to update JSON file/,/^# Function to commit/{ /^# Function to commit/d; p; }' "$RUN_SH" >> "${dir}/test_harness.sh"
    echo "${2:-update_json}" >> "${dir}/test_harness.sh"
    chmod +x "${dir}/test_harness.sh"
}

# Exit status of the most recent run_health_harness call.
LAST_HARNESS_STATUS=0

# Run the harness built in $1 with the environment assignments in "$@".
run_health_harness() {
    local dir="$1"
    shift
    local output
    # `env` is required: assignments that arrive as expanded words are ordinary
    # arguments, not assignments.
    output=$(cd "$dir" && env RUN_SH="$RUN_SH" "$@" bash test_harness.sh 2>&1) && \
        LAST_HARNESS_STATUS=0 || LAST_HARNESS_STATUS=$?
    printf '%s\n' "$output"
    # Returned as well as recorded: a caller inside $( ) gets a subshell, so
    # the global alone would not reach it.
    return "$LAST_HARNESS_STATUS"
}
