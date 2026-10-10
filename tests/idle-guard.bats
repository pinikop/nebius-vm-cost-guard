#!/usr/bin/env bats

setup() {
    TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/bin" "$TEST_DIR/app" "$TEST_DIR/state"
    cp "$BATS_TEST_DIRNAME/../idle-guard.sh" "$TEST_DIR/app/"
    NEBIUS_CALLS="$TEST_DIR/nebius_calls"
    GPU_OUTPUT="$TEST_DIR/gpu_output"

    # Mock nebius: record the call, report the tested version. Never touches a real VM.
    cat > "$TEST_DIR/bin/nebius" <<EOF
#!/bin/bash
[[ "\$1" == "version" ]] && { echo "0.12.287"; exit 0; }
echo "\$*" >> "$NEBIUS_CALLS"
EOF

    # Mock nvidia-smi: print the prepared output, or fail if gpu_fail exists.
    cat > "$TEST_DIR/bin/nvidia-smi" <<EOF
#!/bin/bash
[[ -f "$TEST_DIR/gpu_fail" ]] && exit 9
cat "$GPU_OUTPUT"
EOF
    # Mock logger so tests never write to the real syslog.
    cat > "$TEST_DIR/bin/logger" <<EOF
#!/bin/bash
echo "\$*" >> "$TEST_DIR/logger_calls"
EOF
    chmod +x "$TEST_DIR/bin/"*

    unset NVIDIA_SMI GPU_MONITORING GPU_THRESHOLD GPU_SAMPLES GPU_SAMPLE_INTERVAL \
        GPU_MEMORY_THRESHOLD_MB GPU_MEM_IDLE_THRESHOLD_SECONDS
    write_config
    echo 1 > "$TEST_DIR/state/idle_since"
    export PATH="$TEST_DIR/bin:$PATH"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# write_config [extra config lines...]: CPU idle by default.
write_config() {
    cat > "$TEST_DIR/app/config.env" <<EOF
INSTANCE_ID="test-id"
CPU_THRESHOLD=100000
IDLE_THRESHOLD_SECONDS=1800
MIN_UPTIME_SECONDS=0
LOG_FILE="$TEST_DIR/log"
STATE_FILE="$TEST_DIR/state/idle_since"
ENABLED="true"
GPU_SAMPLES=2
GPU_SAMPLE_INTERVAL=0
EOF
    printf '%s\n' "$@" >> "$TEST_DIR/app/config.env"
}

set_gpu() {
    printf '%b\n' "$1" > "$GPU_OUTPUT"
}

run_guard() {
    run bash "$TEST_DIR/app/idle-guard.sh"
}

assert_stopped() {
    grep -q "compute instance stop --id test-id" "$NEBIUS_CALLS"
}

assert_not_stopped() {
    [[ ! -f "$NEBIUS_CALLS" ]]
}

@test "CPU idle, no GPU monitoring: stops VM" {
    write_config 'GPU_MONITORING="off"'
    run_guard
    [ "$status" -eq 0 ]
    assert_stopped
}

@test "CPU busy: does not stop VM and resets idle timer" {
    write_config 'GPU_MONITORING="off"' 'CPU_THRESHOLD=0'
    run_guard
    [ "$status" -eq 0 ]
    assert_not_stopped
    [[ ! -f "$TEST_DIR/state/idle_since" ]]
}

@test "no GPU (auto, nvidia-smi missing): CPU-only behavior, stops VM" {
    write_config 'GPU_MONITORING="auto"' 'NVIDIA_SMI="/nonexistent/nvidia-smi"'
    run_guard
    [ "$status" -eq 0 ]
    assert_stopped
    ! grep -q "GPU" "$TEST_DIR/log"
}

@test "one idle GPU: stops VM and logs CPU and GPU on one line" {
    set_gpu "0, 10"
    run_guard
    [ "$status" -eq 0 ]
    assert_stopped
    grep -qE "CPU usage.*\| GPU usage" "$TEST_DIR/log"
}

@test "one busy GPU: does not stop VM and resets idle timer" {
    set_gpu "90, 5000"
    run_guard
    [ "$status" -eq 0 ]
    assert_not_stopped
    [[ ! -f "$TEST_DIR/state/idle_since" ]]
}

@test "multi-GPU with one busy: does not stop VM" {
    set_gpu "0, 10\n80, 9000"
    run_guard
    [ "$status" -eq 0 ]
    assert_not_stopped
}

@test "multi-GPU, busy one listed last: does not stop VM" {
    set_gpu "0, 10\n6, 10"
    run_guard
    assert_not_stopped
}

@test "nvidia-smi failing: does not stop VM, logs ERROR" {
    touch "$TEST_DIR/gpu_fail"
    run_guard
    [ "$status" -eq 0 ]
    assert_not_stopped
    grep -q "ERROR" "$TEST_DIR/log"
}

@test "nvidia-smi garbage output: does not stop VM" {
    set_gpu "[N/A], [N/A]"
    run_guard
    assert_not_stopped
    grep -q "ERROR" "$TEST_DIR/log"
}

@test "GPU_MONITORING=on with nvidia-smi missing: does not stop VM" {
    write_config 'GPU_MONITORING="on"' 'NVIDIA_SMI="/nonexistent/nvidia-smi"'
    run_guard
    assert_not_stopped
    grep -q "ERROR" "$TEST_DIR/log"
}

@test "GPU_MONITORING=off ignores a busy GPU" {
    write_config 'GPU_MONITORING="off"'
    set_gpu "99, 9000"
    run_guard
    assert_stopped
}

@test "CPU busy, GPU idle: does not stop VM" {
    write_config 'CPU_THRESHOLD=0'
    set_gpu "0, 10"
    run_guard
    [ "$status" -eq 0 ]
    assert_not_stopped
}

@test "unknown GPU_MONITORING value: treated as on" {
    write_config 'GPU_MONITORING="bogus"'
    set_gpu "99, 9000"
    run_guard
    [ "$status" -eq 0 ]
    assert_not_stopped
}

@test "leading-zero GPU util 08: does not stop VM" {
    set_gpu "08, 10"
    run_guard
    [ "$status" -eq 0 ]
    assert_not_stopped
}

@test "leading-zero GPU util 09: does not stop VM" {
    set_gpu "09, 10"
    run_guard
    [ "$status" -eq 0 ]
    assert_not_stopped
}

@test "overflowing GPU util: does not stop VM" {
    set_gpu "18446744073709551616, 10"
    run_guard
    [ "$status" -eq 0 ]
    assert_not_stopped
    grep -q "ERROR" "$TEST_DIR/log"
}

@test "non-numeric GPU_SAMPLE_INTERVAL: does not stop VM" {
    write_config 'GPU_SAMPLE_INTERVAL="abc"'
    set_gpu "0, 10"
    run_guard
    [ "$status" -eq 0 ]
    assert_not_stopped
    grep -q "ERROR" "$TEST_DIR/log"
}

@test "non-numeric GPU_THRESHOLD: does not stop VM" {
    write_config 'GPU_THRESHOLD="abc"'
    set_gpu "0, 10"
    run_guard
    [ "$status" -eq 0 ]
    assert_not_stopped
    grep -q "ERROR" "$TEST_DIR/log"
}

@test "memory held, idle 2000s: not stopped (limit 3600)" {
    write_config 'GPU_MEMORY_THRESHOLD_MB=1024'
    set_gpu "0, 2000"
    echo $(($(date +%s) - 2000)) > "$TEST_DIR/state/idle_since"
    run_guard
    assert_not_stopped
    [[ -f "$TEST_DIR/state/idle_since" ]]
}

@test "memory held, idle 4000s: stopped, log shows memory limit" {
    write_config 'GPU_MEMORY_THRESHOLD_MB=1024'
    set_gpu "0, 2000"
    echo $(($(date +%s) - 4000)) > "$TEST_DIR/state/idle_since"
    run_guard
    assert_stopped
    grep -q "memory held: limit 3600s" "$TEST_DIR/log"
}

@test "memory below threshold, idle 2000s: stopped (normal limit)" {
    write_config 'GPU_MEMORY_THRESHOLD_MB=1024'
    set_gpu "0, 100"
    echo $(($(date +%s) - 2000)) > "$TEST_DIR/state/idle_since"
    run_guard
    assert_stopped
}

@test "memory option off (default), memory held, idle 2000s: stopped" {
    set_gpu "0, 20000"
    echo $(($(date +%s) - 2000)) > "$TEST_DIR/state/idle_since"
    run_guard
    assert_stopped
}

@test "non-numeric GPU_MEMORY_THRESHOLD_MB: does not stop VM" {
    write_config 'GPU_MEMORY_THRESHOLD_MB="abc"'
    set_gpu "0, 10"
    run_guard
    [ "$status" -eq 0 ]
    assert_not_stopped
    grep -q "ERROR" "$TEST_DIR/log"
}

@test "memory limit shorter than normal limit: never shortens (600s, idle 1000s)" {
    write_config 'GPU_MEMORY_THRESHOLD_MB=1024' 'GPU_MEM_IDLE_THRESHOLD_SECONDS=600'
    set_gpu "0, 2000"
    echo $(($(date +%s) - 1000)) > "$TEST_DIR/state/idle_since"
    run_guard
    [ "$status" -eq 0 ]
    assert_not_stopped
}

@test "memory limit 0: never shortens (idle 1000s)" {
    write_config 'GPU_MEMORY_THRESHOLD_MB=1024' 'GPU_MEM_IDLE_THRESHOLD_SECONDS=0'
    set_gpu "0, 2000"
    echo $(($(date +%s) - 1000)) > "$TEST_DIR/state/idle_since"
    run_guard
    [ "$status" -eq 0 ]
    assert_not_stopped
}

@test "overflowing GPU_MEM_IDLE_THRESHOLD_SECONDS: does not stop VM" {
    write_config 'GPU_MEMORY_THRESHOLD_MB=1024' 'GPU_MEM_IDLE_THRESHOLD_SECONDS=9223372036854775808'
    set_gpu "0, 2000"
    echo $(($(date +%s) - 10)) > "$TEST_DIR/state/idle_since"
    run_guard
    [ "$status" -eq 0 ]
    assert_not_stopped
    grep -q "ERROR" "$TEST_DIR/log"
}

@test "non-numeric GPU_MEM_IDLE_THRESHOLD_SECONDS: does not stop VM" {
    write_config 'GPU_MEMORY_THRESHOLD_MB=1024' 'GPU_MEM_IDLE_THRESHOLD_SECONDS="abc"'
    set_gpu "0, 2000"
    run_guard
    [ "$status" -eq 0 ]
    assert_not_stopped
    grep -q "ERROR" "$TEST_DIR/log"
}

@test "memory held, idle 3500s: not stopped" {
    write_config 'GPU_MEMORY_THRESHOLD_MB=1024'
    set_gpu "0, 2000"
    echo $(($(date +%s) - 3500)) > "$TEST_DIR/state/idle_since"
    run_guard
    assert_not_stopped
}

@test "memory held, idle 3601s: stopped" {
    write_config 'GPU_MEMORY_THRESHOLD_MB=1024'
    set_gpu "0, 2000"
    echo $(($(date +%s) - 3601)) > "$TEST_DIR/state/idle_since"
    run_guard
    assert_stopped
}

@test "memory exactly at threshold counts as held" {
    write_config 'GPU_MEMORY_THRESHOLD_MB=2000'
    set_gpu "0, 2000"
    echo $(($(date +%s) - 2000)) > "$TEST_DIR/state/idle_since"
    run_guard
    assert_not_stopped
}

@test "memory one below threshold is not held" {
    write_config 'GPU_MEMORY_THRESHOLD_MB=2000'
    set_gpu "0, 1999"
    echo $(($(date +%s) - 2000)) > "$TEST_DIR/state/idle_since"
    run_guard
    assert_stopped
}

@test "memory held but GPU util above threshold: not stopped, timer reset" {
    write_config 'GPU_MEMORY_THRESHOLD_MB=1024'
    set_gpu "50, 2000"
    echo $(($(date +%s) - 4000)) > "$TEST_DIR/state/idle_since"
    run_guard
    [ "$status" -eq 0 ]
    assert_not_stopped
    [[ ! -f "$TEST_DIR/state/idle_since" ]]
}

@test "ERROR is also written to the status file and syslog" {
    touch "$TEST_DIR/gpu_fail"
    run_guard
    [ "$status" -eq 0 ]
    grep -q "nvidia-smi failed" "$TEST_DIR/state/last_error"
    grep -q "cost-guard.*nvidia-smi failed" "$TEST_DIR/logger_calls"
}

@test "a run without errors clears the status file" {
    echo "old error" > "$TEST_DIR/state/last_error"
    set_gpu "0, 10"
    run_guard
    [ "$status" -eq 0 ]
    [[ ! -f "$TEST_DIR/state/last_error" ]]
}

@test "INFO and WARN do not create the status file" {
    set_gpu "0, 10"
    run_guard
    [[ ! -f "$TEST_DIR/state/last_error" ]]
    [[ ! -f "$TEST_DIR/logger_calls" ]]
}
