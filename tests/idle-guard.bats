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
    assert_not_stopped
}

@test "unknown GPU_MONITORING value: treated as on" {
    write_config 'GPU_MONITORING="bogus"'
    set_gpu "99, 9000"
    run_guard
    assert_not_stopped
}
