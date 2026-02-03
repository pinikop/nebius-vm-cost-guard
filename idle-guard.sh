#!/bin/bash
#
# Nebius VM Cost Guard - Idle Shutdown Script
#
set -euo pipefail

# Ensure PATH is set for cron
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.nebius/bin"

# Load configuration
CONFIG_FILE="$(dirname "$0")/config.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

STATE_DIR=$(dirname "$STATE_FILE")

# Create state directory if it doesn't exist
if [[ ! -d "$STATE_DIR" ]]; then
    mkdir -p "$STATE_DIR" || { echo "ERROR: Cannot create state dir $STATE_DIR"; exit 1; }
fi

# Logging
log() {
    local level="$1"
    shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*" >> "$LOG_FILE" 2>&1
}

# Get CPU usage based on 5-minute load average
get_cpu_usage() {
    local lavg=$(awk '{print $2}' /proc/loadavg)
    local cpus=$(nproc)
    awk -v l="$lavg" -v c="$cpus" 'BEGIN {printf "%.0f", (l / c) * 100}'
}

# TODO: Add GPU monitoring support

# Get system uptime in seconds
get_uptime_seconds() {
    awk '{print int($1)}' /proc/uptime
}

main() {
    log "INFO" "--- Cost Guard check starting ---"
    
    if [[ "${ENABLED:-false}" != "true" ]]; then
        log "INFO" "Cost Guard is disabled."
        exit 0
    fi
    
    local uptime=$(get_uptime_seconds)
    if [[ $uptime -lt $MIN_UPTIME_SECONDS ]]; then
        log "INFO" "Uptime ($uptime s) < Min ($MIN_UPTIME_SECONDS s). Skipping."
        rm -f "$STATE_FILE"
        exit 0
    fi
    
    local cpu_usage=$(get_cpu_usage)
    log "INFO" "CPU usage (5-min avg): ${cpu_usage}% (Threshold: ${CPU_THRESHOLD}%)"
    
    if [[ $cpu_usage -lt $CPU_THRESHOLD ]]; then
        local now=$(date +%s)
        
        if [[ -f "$STATE_FILE" ]]; then
            local idle_since=$(cat "$STATE_FILE")
            local idle_duration=$((now - idle_since))
            
            log "INFO" "Idle for ${idle_duration}s (Threshold: ${IDLE_THRESHOLD_SECONDS}s)"
            
            if [[ $idle_duration -ge $IDLE_THRESHOLD_SECONDS ]]; then
                log "WARN" "IDLE THRESHOLD EXCEEDED! Initiating shutdown."
                
                # Use service account authentication (automatic via instance metadata)
                if nebius compute instance update \
                    --id "$INSTANCE_ID" \
                    --stopped >> "$LOG_FILE" 2>&1; then
                    log "INFO" "Shutdown command sent successfully."
                else
                    log "ERROR" "Nebius CLI command failed."
                    exit 1
                fi
            fi
        else
            echo "$now" > "$STATE_FILE"
            log "INFO" "Started idle tracking at $(date -d "@$now" '+%Y-%m-%d %H:%M:%S')"
        fi
    else
        if [[ -f "$STATE_FILE" ]]; then
            log "INFO" "CPU above threshold. Resetting idle timer."
            rm -f "$STATE_FILE"
        else
            log "INFO" "System is active."
        fi
    fi
}

main "$@"
