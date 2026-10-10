# GPU Monitoring Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `idle-guard.sh` stop a VM only when both CPU and GPU are idle, with tests, shellcheck, CI and docs.

**Architecture:** After the CPU check shows idle, sample `nvidia-smi` several times and take the max. Busy or failed GPU checks reset the idle timer. An optional memory-held rule lengthens the idle limit but never blocks shutdown. See `docs/plans/2026-10-09-gpu-monitoring-design.md`.

**Tech Stack:** bash, nvidia-smi, bats-core (tests), shellcheck, GitHub Actions.

Branch: `feature/gpu-monitoring` (based on `feature/nebius-cli-update`). Do not push.

Test conventions used below:
- Tests copy `idle-guard.sh` next to a generated `config.env` in a temp dir, so the script is not modified for testing.
- Mock `nebius` and `nvidia-smi` live in a temp `bin/` placed first on `PATH`. The mock `nebius` only records its arguments.
- The state file is pre-seeded with timestamp `1`, so one tick is enough to decide "stop" or "do not stop".
- `NVIDIA_SMI` (env var, default `nvidia-smi`) lets tests point at a missing binary even on a machine with a real GPU.

---

### Task 1: Test harness, PATH hook, CPU-only baseline

**Files:**
- Modify: `idle-guard.sh:8` (PATH line)
- Create: `tests/idle-guard.bats`

**Step 1: Get bats locally (no sudo, outside the repo)**

```bash
SCRATCH=/tmp/claude-1000/-media-data-projects-cost-guard/e0791d47-ff70-4c37-81c5-4f5e92addcd7/scratchpad
git clone --depth 1 --branch v1.11.1 https://github.com/bats-core/bats-core "$SCRATCH/bats-core"
"$SCRATCH/bats-core/bin/bats" --version
```
Expected: `Bats 1.11.1`. Use `BATS="$SCRATCH/bats-core/bin/bats"` below.

**Step 2: Write the baseline tests**

Create `tests/idle-guard.bats`:

```bash
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
```

**Step 3: Run to verify they fail**

Run: `"$BATS" tests/idle-guard.bats`
Expected: the first test fails (the script's `PATH` line puts the real `nebius` ahead of the mock, or the real CLI is called, and no call is recorded).

**Step 4: Make PATH test-friendly**

In `idle-guard.sh`, change the PATH line to keep the caller's `PATH` first:

```bash
export PATH="$PATH:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.nebius/bin:/root/.nebius/bin"
```

Under cron the minimal `PATH` comes first and the extras are still appended, so behavior is unchanged.

**Step 5: Run to verify they pass**

Run: `"$BATS" tests/idle-guard.bats`
Expected: `2 tests, 0 failures`.

**Step 6: Commit**

```bash
git add idle-guard.sh tests/idle-guard.bats
git commit -m "Add bats harness and CPU-only baseline tests"
```

---

### Task 2: GPU settings in config.env with safe defaults

**Files:**
- Modify: `config.env`
- Modify: `idle-guard.sh` (after `source "$CONFIG_FILE"`)

**Step 1: Add settings to `config.env`**

Insert after the `MIN_UPTIME_SECONDS` line:

```bash

# === GPU Monitoring (NVIDIA only) ===
# A VM is idle only when CPU and GPU are both idle.
GPU_MONITORING="auto"             # auto = use GPU if nvidia-smi exists, on = require it, off = CPU only
GPU_THRESHOLD=5                   # % GPU utilization below which the GPU is "idle"
GPU_SAMPLES=5                     # Samples per check (max is used)
GPU_SAMPLE_INTERVAL=2             # Seconds between samples
GPU_MEMORY_THRESHOLD_MB=0         # >0: GPU holding this much memory at 0% use gets the longer limit below. 0 = ignore memory
GPU_MEM_IDLE_THRESHOLD_SECONDS=3600  # Idle limit used instead of IDLE_THRESHOLD_SECONDS when memory is held
```

**Step 2: Default the settings in the script**

Older `config.env` files lack these, and `set -u` is on. After `source "$CONFIG_FILE"` add:

```bash
GPU_MONITORING="${GPU_MONITORING:-auto}"
GPU_THRESHOLD="${GPU_THRESHOLD:-5}"
GPU_SAMPLES="${GPU_SAMPLES:-5}"
GPU_SAMPLE_INTERVAL="${GPU_SAMPLE_INTERVAL:-2}"
GPU_MEMORY_THRESHOLD_MB="${GPU_MEMORY_THRESHOLD_MB:-0}"
GPU_MEM_IDLE_THRESHOLD_SECONDS="${GPU_MEM_IDLE_THRESHOLD_SECONDS:-3600}"
# Test hook and override for a non-standard nvidia-smi location
NVIDIA_SMI="${NVIDIA_SMI:-nvidia-smi}"
```

**Step 2b: Verify**

Run: `"$BATS" tests/idle-guard.bats`
Expected: still `2 tests, 0 failures`.

**Step 3: Commit**

```bash
git add config.env idle-guard.sh
git commit -m "Add GPU settings with defaults"
```

---

### Task 3: GPU idle detection (TDD)

**Files:**
- Modify: `idle-guard.sh`
- Modify: `tests/idle-guard.bats`

**Step 1: Write the failing tests**

Append to `tests/idle-guard.bats`:

```bash
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
```

**Step 2: Run to verify they fail**

Run: `"$BATS" tests/idle-guard.bats`
Expected: the busy-GPU, multi-GPU, failing and garbage tests fail (GPU is ignored today).

**Step 3: Implement**

In `idle-guard.sh`, replace the `# TODO: Add GPU monitoring support` line with:

```bash
# GPU checks run when GPU_MONITORING is on, or auto with nvidia-smi present.
# Unknown values act like "on" so a typo can never cause a shutdown.
gpu_monitoring_enabled() {
    case "$GPU_MONITORING" in
        off) return 1 ;;
        auto) command -v "$NVIDIA_SMI" > /dev/null ;;
        *) return 0 ;;
    esac
}

# Sample all GPUs GPU_SAMPLES times. Prints "<max_util_pct> <max_mem_mb>".
# Returns non-zero on any nvidia-smi failure or unparsable output.
get_gpu_usage() {
    [[ "$GPU_SAMPLES" =~ ^[1-9][0-9]*$ ]] || return 1
    local max_util=0 max_mem=0 sample out util mem
    for ((sample = 1; sample <= GPU_SAMPLES; sample++)); do
        out=$(timeout 10 "$NVIDIA_SMI" \
            --query-gpu=utilization.gpu,memory.used \
            --format=csv,noheader,nounits 2>/dev/null) || return 1
        [[ -n "$out" ]] || return 1
        while IFS=', ' read -r util mem; do
            [[ "$util" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ ]] || return 1
            if ((util > max_util)); then max_util=$util; fi
            if ((mem > max_mem)); then max_mem=$mem; fi
        done <<< "$out"
        if ((sample < GPU_SAMPLES)); then sleep "$GPU_SAMPLE_INTERVAL"; fi
    done
    echo "$max_util $max_mem"
}

# Returns 0 if the GPU is idle, 1 if active or the check failed (fail-safe).
# Sets GPU_SUMMARY for the log line.
is_gpu_idle() {
    local usage util mem
    if ! usage=$(get_gpu_usage); then
        GPU_SUMMARY="check failed, treated as active"
        log "ERROR" "GPU check failed. Treating GPU as active."
        return 1
    fi
    read -r util mem <<< "$usage"
    GPU_SUMMARY="${util}% (max of ${GPU_SAMPLES} samples, Threshold: ${GPU_THRESHOLD}%, memory: ${mem}MB)"
    ((util < GPU_THRESHOLD))
}
```

Now restructure the start of the idle decision in `main`. Replace this block:

```bash
    local cpu_usage=$(get_cpu_usage)
    log "INFO" "CPU usage (5-min avg): ${cpu_usage}% (Threshold: ${CPU_THRESHOLD}%)"
    
    if [[ $cpu_usage -lt $CPU_THRESHOLD ]]; then
```

with:

```bash
    local cpu_usage
    cpu_usage=$(get_cpu_usage)
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
```

And change the final `else` branch message:

```bash
            log "INFO" "CPU or GPU above threshold. Resetting idle timer."
```

**Step 4: Run to verify they pass**

Run: `"$BATS" tests/idle-guard.bats`
Expected: all tests pass (13 total).

**Step 5: Commit**

```bash
git add idle-guard.sh tests/idle-guard.bats
git commit -m "Add GPU-aware idle detection"
```

---

### Task 4: Memory-held grace period (TDD)

**Files:**
- Modify: `idle-guard.sh`
- Modify: `tests/idle-guard.bats`

**Step 1: Write the failing tests**

```bash
@test "memory held, idle 2000s: not stopped (limit 3600)" {
    write_config 'GPU_MEMORY_THRESHOLD_MB=1024'
    set_gpu "0, 2000"
    echo $(($(date +%s) - 2000)) > "$TEST_DIR/state/idle_since"
    run_guard
    assert_not_stopped
    [[ -f "$TEST_DIR/state/idle_since" ]]
}

@test "memory held, idle 4000s: stopped" {
    write_config 'GPU_MEMORY_THRESHOLD_MB=1024'
    set_gpu "0, 2000"
    echo $(($(date +%s) - 4000)) > "$TEST_DIR/state/idle_since"
    run_guard
    assert_stopped
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
```

**Step 2: Run to verify they fail**

Run: `"$BATS" tests/idle-guard.bats`
Expected: "memory held, idle 2000s: not stopped" fails.

**Step 3: Implement**

In `main`, before the CPU check, add `IDLE_LIMIT=$IDLE_THRESHOLD_SECONDS`. In `is_gpu_idle`, replace the last line (`((util < GPU_THRESHOLD))`) with:

```bash
    ((util < GPU_THRESHOLD)) || return 1
    if ((GPU_MEMORY_THRESHOLD_MB > 0 && mem >= GPU_MEMORY_THRESHOLD_MB)); then
        IDLE_LIMIT=$GPU_MEM_IDLE_THRESHOLD_SECONDS
    fi
```

Declare `IDLE_LIMIT=$IDLE_THRESHOLD_SECONDS` at script level after the settings defaults (so `is_gpu_idle` can set it, and `main` resets it per run since each run is a new process). In `main`, replace both uses of `$IDLE_THRESHOLD_SECONDS` in the idle branch (the log line and the `-ge` comparison) with `$IDLE_LIMIT`.

**Step 4: Run to verify they pass**

Run: `"$BATS" tests/idle-guard.bats`
Expected: all pass (17 total).

**Step 5: Commit**

```bash
git add idle-guard.sh tests/idle-guard.bats
git commit -m "Add memory-held grace period"
```

---

### Task 5: Shellcheck clean

**Files:** `idle-guard.sh`

**Step 1: Run**

Run: `shellcheck idle-guard.sh`
Expected: SC1090 on `source "$CONFIG_FILE"` and SC2155 on `local x=$(...)` lines.

**Step 2: Fix**

- Above `source "$CONFIG_FILE"` add `# shellcheck source=/dev/null`.
- Split each `local var=$(cmd)` into `local var` and `var=$(cmd)` (`lavg`, `cpus`, `uptime`, `now`, `idle_since`).

Do not change logic.

**Step 3: Verify**

Run: `shellcheck idle-guard.sh && "$BATS" tests/idle-guard.bats`
Expected: no shellcheck output; all tests pass.

**Step 4: Commit**

```bash
git add idle-guard.sh
git commit -m "Fix shellcheck warnings"
```

---

### Task 6: GitHub Actions

**Files:** Create `.github/workflows/ci.yml`

```yaml
name: CI

on:
  push:
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install tools
        run: sudo apt-get update && sudo apt-get install -y shellcheck bats
      - name: Shellcheck
        run: shellcheck idle-guard.sh
      - name: Bats
        run: bats tests/
```

Verify locally: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"`.
Not verifiable here: the actual Actions run (no push). The distro `bats` package is 1.10 on ubuntu-latest (24.04); the tests use only basic features.

Commit: `git add .github && git commit -m "Add CI workflow"`.

---

### Task 7: README

**Files:** Modify `README.md`

- **How It Works:** step 2-4 mention GPU. Add a "GPU detection" subsection: both CPU and GPU must be idle; `nvidia-smi` sampled `GPU_SAMPLES` times `GPU_SAMPLE_INTERVAL` s apart, max over samples and GPUs; busy or failed check resets the timer; memory option and longer limit; NVIDIA only; sampling covers about 8 s per 5-minute tick so bursty workloads can be missed.
- **Config table:** add rows for `GPU_MONITORING`, `GPU_THRESHOLD`, `GPU_SAMPLES`, `GPU_SAMPLE_INTERVAL`, `GPU_MEMORY_THRESHOLD_MB`, `GPU_MEM_IDLE_THRESHOLD_SECONDS`.
- **Testing:** add "GPU testing" after the CPU section: run a GPU load (for example `python3 -c "import torch; ..."`-style or `gpu-burn`), run the script with test thresholds, confirm the log shows GPU above threshold and the timer resets; then stop the load and confirm shutdown. Mention `GPU_MONITORING=off` to compare.
- **Development:** `shellcheck idle-guard.sh` and `bats tests/`.
- Keep the tested CLI version note added earlier.

Commit: `git commit -am "Document GPU monitoring"`.

---

### Task 8: Final verification

1. `shellcheck idle-guard.sh` - no output.
2. `"$BATS" tests/` - all pass.
3. Real-machine smoke test (this host has an RTX 2060, no `nebius` stop must run): copy the repo to a temp dir, use a config with `STATE_FILE` and `LOG_FILE` in the temp dir and a mock `nebius` first on `PATH`, run once with the GPU idle and once while a GPU load runs. Confirm the log line shows real values and the mock is never called when the GPU is busy.
4. `git log --oneline` shows one logical change per commit. Do not push.
