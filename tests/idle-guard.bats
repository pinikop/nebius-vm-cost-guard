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
$*
EOF
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
