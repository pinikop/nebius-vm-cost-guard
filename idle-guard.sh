#!/bin/bash
#
# Nebius VM Cost Guard - Idle Shutdown Script
#
set -euo pipefail

# Nebius CLI version this script was tested with
TESTED_NEBIUS_VERSION="0.12.287"

# Ensure PATH is set for cron (cron may not set HOME to the CLI owner's home)
export PATH="$PATH:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.nebius/bin:/root/.nebius/bin"

# Load configuration
CONFIG_FILE="$(dirname "$0")/config.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"
GPU_MONITORING="${GPU_MONITORING:-auto}"
GPU_THRESHOLD="${GPU_THRESHOLD:-5}"
GPU_SAMPLES="${GPU_SAMPLES:-5}"
GPU_SAMPLE_INTERVAL="${GPU_SAMPLE_INTERVAL:-2}"
GPU_MEMORY_THRESHOLD_MB="${GPU_MEMORY_THRESHOLD_MB:-0}"
GPU_MEM_IDLE_THRESHOLD_SECONDS="${GPU_MEM_IDLE_THRESHOLD_SECONDS:-3600}"
# Test hook and override for a non-standard nvidia-smi location
NVIDIA_SMI="${NVIDIA_SMI:-nvidia-smi}"
# Exists while the NVIDIA kernel driver is loaded (test hook like NVIDIA_SMI)
NVIDIA_DRIVER_DIR="${NVIDIA_DRIVER_DIR:-/proc/driver/nvidia}"
# Idle time required before shutdown; raised or lowered per check by is_gpu_idle
IDLE_LIMIT=$IDLE_THRESHOLD_SECONDS

STATE_DIR=$(dirname "$STATE_FILE")

# Create state directory if it doesn't exist
if [[ ! -d "$STATE_DIR" ]]; then
    mkdir -p "$STATE_DIR" || { echo "ERROR: Cannot create state dir $STATE_DIR"; exit 1; }
fi

# Status file shown at login (see README). It exists only if the last run logged an ERROR.
ERROR_FILE="$STATE_DIR/last_error"

# Surface an error beyond the log file: status file for the login banner, syslog if available
report_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$ERROR_FILE" 2>/dev/null || true
    if command -v logger > /dev/null; then
        logger -t cost-guard -p user.err -- "$1" || true
    fi
}

# Logging
log() {
    local level="$1"
    shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*" >> "$LOG_FILE" 2>&1
    if [[ "$level" == "ERROR" ]]; then report_error "$*"; fi
}

# Get CPU usage based on 5-minute load average
get_cpu_usage() {
    local lavg cpus
    lavg=$(awk '{print $2}' /proc/loadavg)
    cpus=$(nproc)
    awk -v l="$lavg" -v c="$cpus" 'BEGIN {printf "%.0f", (l / c) * 100}'
}

# GPU checks run when GPU_MONITORING is on, or auto with nvidia-smi present or the
# NVIDIA driver loaded (a loaded driver without nvidia-smi must not look like "no GPU").
# Unknown values act like "on" so a typo can never cause a shutdown.
gpu_monitoring_enabled() {
    case "$GPU_MONITORING" in
        off) return 1 ;;
        auto) command -v "$NVIDIA_SMI" > /dev/null || [[ -d "$NVIDIA_DRIVER_DIR" ]] ;;
        *) return 0 ;;
    esac
}

# Longest time one check may spend waiting between GPU samples. Longer runs would overlap
# the next cron run.
GPU_MAX_SAMPLING_SECONDS=120

# Returns non-zero if any GPU setting is not numeric or the samples would take too long.
# Integers are capped at 9 digits so 10# arithmetic cannot overflow.
gpu_settings_valid() {
    [[ "$GPU_SAMPLES" =~ ^[1-9][0-9]{0,8}$ ]] &&
        [[ "$GPU_SAMPLE_INTERVAL" =~ ^[0-9]+(\.[0-9]+)?$ ]] &&
        [[ "$GPU_THRESHOLD" =~ ^[0-9]{1,9}$ ]] &&
        [[ "$GPU_MEMORY_THRESHOLD_MB" =~ ^[0-9]{1,9}$ ]] &&
        [[ "$GPU_MEM_IDLE_THRESHOLD_SECONDS" =~ ^[0-9]{1,9}$ ]] &&
        awk -v i="$GPU_SAMPLE_INTERVAL" -v n="$GPU_SAMPLES" -v max="$GPU_MAX_SAMPLING_SECONDS" \
            'BEGIN { exit !(i * (n - 1) <= max) }'
}

# Exits non-zero if a core setting is not a plain integer (capped at 9 digits so
# arithmetic cannot overflow). An empty value would otherwise act as 0 and stop the VM.
core_settings_valid() {
    # shellcheck disable=SC2153 # CPU_THRESHOLD comes from config.env, not a typo for GPU_THRESHOLD
    [[ "$IDLE_THRESHOLD_SECONDS" =~ ^[0-9]{1,9}$ ]] &&
        [[ "$CPU_THRESHOLD" =~ ^[0-9]{1,9}$ ]] &&
        [[ "$MIN_UPTIME_SECONDS" =~ ^[0-9]{1,9}$ ]]
}

# Write the idle start time atomically so an interrupted write cannot leave an empty file
write_state() {
    echo "$1" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# Sample all GPUs GPU_SAMPLES times. Prints "<max_util_pct> <max_mem_mb>".
# Logs the reason and returns non-zero on any nvidia-smi failure or unparsable output.
get_gpu_usage() {
    local max_util=0 max_mem=0 sample out util mem
    if ! command -v "$NVIDIA_SMI" > /dev/null; then
        log "ERROR" "nvidia-smi not found, but GPU monitoring is on or the NVIDIA driver is loaded. Treating GPU as active."
        return 1
    fi
    for ((sample = 1; sample <= GPU_SAMPLES; sample++)); do
        out=$(timeout -k 5 10 "$NVIDIA_SMI" \
            --query-gpu=utilization.gpu,memory.used \
            --format=csv,noheader,nounits 2>/dev/null) || {
            log "ERROR" "nvidia-smi failed or timed out. Treating GPU as active."
            return 1
        }
        [[ -n "$out" ]] || {
            log "ERROR" "Empty nvidia-smi output. Treating GPU as active."
            return 1
        }
        while IFS=', ' read -r util mem; do
            # 10# avoids octal parsing of values like 08
            if [[ ! "$util" =~ ^[0-9]{1,3}$ || ! "$mem" =~ ^[0-9]{1,9}$ ]]; then
                log "ERROR" "Unparsable nvidia-smi output. Treating GPU as active."
                return 1
            fi
            if ((10#$util > max_util)); then max_util=$((10#$util)); fi
            if ((10#$mem > max_mem)); then max_mem=$((10#$mem)); fi
        done <<< "$out"
        if ((sample < GPU_SAMPLES)); then sleep "$GPU_SAMPLE_INTERVAL"; fi
    done
    echo "$max_util $max_mem"
}

# Returns 0 if the GPU is idle, 1 if active or the check failed (fail-safe).
# Sets GPU_SUMMARY for the log line.
is_gpu_idle() {
    local usage util mem
    if ! gpu_settings_valid; then
        GPU_SUMMARY="check failed, treated as active"
        log "ERROR" "Invalid GPU settings. Treating GPU as active."
        return 1
    fi
    if ! usage=$(get_gpu_usage); then
        GPU_SUMMARY="check failed, treated as active"
        return 1
    fi
    read -r util mem <<< "$usage"
    GPU_SUMMARY="${util}% (max of ${GPU_SAMPLES} samples, Threshold: ${GPU_THRESHOLD}%, memory: ${mem}MB)"
    ((util < 10#$GPU_THRESHOLD)) || return 1
    # Memory held by an idle process: allow a longer grace period before stopping.
    # Memory only lengthens the limit, never shortens it.
    if ((10#$GPU_MEMORY_THRESHOLD_MB > 0 && mem >= 10#$GPU_MEMORY_THRESHOLD_MB)); then
        if ((10#$GPU_MEM_IDLE_THRESHOLD_SECONDS > IDLE_LIMIT)); then
            IDLE_LIMIT=$((10#$GPU_MEM_IDLE_THRESHOLD_SECONDS))
        fi
        GPU_SUMMARY+=", memory held: limit ${IDLE_LIMIT}s"
    fi
}

# Log an error if the Nebius CLI is missing, a warning if its version differs from the tested one
check_nebius_cli() {
    if ! command -v nebius > /dev/null; then
        log "ERROR" "nebius CLI not found in PATH. Shutdown will fail."
        return 0
    fi
    local version
    version=$(timeout -k 5 10 nebius version 2>/dev/null | head -n1 || true)
    if [[ "$version" != "$TESTED_NEBIUS_VERSION" ]]; then
        log "WARN" "nebius CLI version '${version:-unknown}' differs from tested $TESTED_NEBIUS_VERSION."
    fi
}

# Print the instance ID: config override, else instance metadata service.
# Fails if the value is missing or does not look like an ID, so junk is never passed to the CLI.
get_instance_id() {
    local id="${INSTANCE_ID:-}"
    if [[ -z "$id" ]]; then
        id=$(curl -sf -m 5 -H "Metadata: true" \
            "http://metadata.nebius.internal/v1/instance-data/id") || return 1
    fi
    [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 1
    echo "$id"
}

# Log an error now if the ID cannot be determined, instead of at shutdown time 30+ minutes later
check_instance_id() {
    if ! get_instance_id > /dev/null; then
        log "ERROR" "Cannot determine a valid instance ID. Shutdown will not happen."
    fi
}

# Get system uptime in seconds
get_uptime_seconds() {
    awk '{print int($1)}' /proc/uptime
}

# Allow only one check at a time. Cron starts a new run every interval even if the previous
# one is still going (hung nvidia-smi or CLI, a slow stop command, or a manual run), and
# overlapping runs could race on the state file or send duplicate stop commands.
# Without flock the script runs unlocked, as before.
acquire_lock() {
    command -v flock > /dev/null || return 0
    exec 9> "$STATE_DIR/lock"
    flock -n 9
}

main() {
    if ! acquire_lock; then
        log "INFO" "Previous run still active. Skipping."
        exit 0
    fi
    rm -f "$ERROR_FILE"
    log "INFO" "--- Cost Guard check starting ---"
    IDLE_LIMIT=$IDLE_THRESHOLD_SECONDS
    
    if [[ "${ENABLED:-false}" != "true" ]]; then
        log "INFO" "Cost Guard is disabled."
        exit 0
    fi
    
    if ! core_settings_valid; then
        log "ERROR" "Invalid IDLE_THRESHOLD_SECONDS, CPU_THRESHOLD or MIN_UPTIME_SECONDS. Not checking."
        exit 1
    fi

    local uptime
    uptime=$(get_uptime_seconds)
    if [[ $uptime -lt $MIN_UPTIME_SECONDS ]]; then
        log "INFO" "Uptime ($uptime s) < Min ($MIN_UPTIME_SECONDS s). Skipping."
        rm -f "$STATE_FILE"
        exit 0
    fi
    
    local cpu_usage
    cpu_usage=$(get_cpu_usage)
    # shellcheck disable=SC2153 # CPU_THRESHOLD comes from config.env, not a typo for GPU_THRESHOLD
    local status="CPU usage (5-min avg): ${cpu_usage}% (Threshold: ${CPU_THRESHOLD}%)"
    local idle=false

    if [[ $cpu_usage -lt $CPU_THRESHOLD ]]; then
        if ! gpu_monitoring_enabled; then
            idle=true
        else
            if is_gpu_idle; then idle=true; fi
            status+=" | GPU usage: $GPU_SUMMARY"
        fi
    elif gpu_monitoring_enabled; then
        status+=" | GPU usage: not checked (CPU busy)"
    fi
    log "INFO" "$status"

    if [[ $idle == true ]]; then
        local now
        now=$(date +%s)
        
        if [[ -f "$STATE_FILE" ]]; then
            local idle_since
            idle_since=$(cat "$STATE_FILE")
            if [[ ! "$idle_since" =~ ^[0-9]{1,10}$ ]]; then
                log "WARN" "Invalid state file content. Restarting idle tracking."
                idle_since=$now
                write_state "$now"
            fi
            local idle_duration=$((now - 10#$idle_since))
            
            log "INFO" "Idle for ${idle_duration}s (Threshold: ${IDLE_LIMIT}s)"
            
            if [[ $idle_duration -ge $IDLE_LIMIT ]]; then
                log "WARN" "IDLE THRESHOLD EXCEEDED! Initiating shutdown."
                
                local instance_id
                if ! instance_id=$(get_instance_id); then
                    log "ERROR" "Cannot determine a valid instance ID. Not stopping."
                    exit 1
                fi

                # Use service account authentication (automatic via instance metadata)
                if nebius compute instance stop \
                    --id "$instance_id" >> "$LOG_FILE" 2>&1; then
                    log "INFO" "Shutdown command sent successfully."
                else
                    log "ERROR" "Nebius CLI command failed."
                    exit 1
                fi
            fi
        else
            write_state "$now"
            check_nebius_cli
            check_instance_id
            log "INFO" "Started idle tracking at $(date -d "@$now" '+%Y-%m-%d %H:%M:%S')"
        fi
    else
        if [[ -f "$STATE_FILE" ]]; then
            log "INFO" "CPU or GPU busy, or GPU check failed. Resetting idle timer."
            rm -f "$STATE_FILE"
        else
            log "INFO" "System is active."
        fi
    fi
}

main "$@"
