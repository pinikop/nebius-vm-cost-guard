# GPU-aware idle detection - design

## Goal

A VM is idle only when CPU and GPU are both idle. CPU-only VMs behave exactly as today with no config changes. A VM with a busy GPU is never stopped.

## Detection

`GPU_MONITORING=auto|on|off` (default `auto`).

- `auto`: use the GPU if `nvidia-smi` exists, otherwise CPU only.
- `on`: `nvidia-smi` must exist. If missing, log an error and treat the GPU as active.
- `off`: CPU only.

NVIDIA only.

## Metric and sampling

`nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits`, wrapped in `timeout 10`.

- Take `GPU_SAMPLES` (5) samples `GPU_SAMPLE_INTERVAL` (2) seconds apart.
- Use the max utilization over all samples and all GPUs. The VM is GPU-idle only if it is below `GPU_THRESHOLD` (5).
- Cron runs every 5 minutes, so the GPU is observed about 8 s per tick. Bursty workloads can slip through. Documented as a limit.
- Sampling runs only when CPU is already idle, so busy-CPU ticks skip the delay.

## Memory

`GPU_MEMORY_THRESHOLD_MB` (default `0` = memory ignored).

If above 0 and any GPU holds at least that much memory at idle utilization, the shutdown threshold is `GPU_MEM_IDLE_THRESHOLD_SECONDS` (3600) instead of `IDLE_THRESHOLD_SECONDS` (1800). Memory never blocks shutdown outright, so a stuck process cannot keep the VM alive forever.

## Fail-safe

`nvidia-smi` missing under `on`, failing, timing out, or returning non-numeric output: treat the GPU as active, log an ERROR, reset the idle timer. Never stop because a check failed.

## Structure

- `get_gpu_usage`: prints `<max_util> <max_mem_mb>`; non-zero exit on failure.
- `is_gpu_idle`: wraps it, sets the active threshold, returns idle/active.
- `main`: after the CPU check shows idle, run the GPU check. Busy or failed resets the timer. State file stays a single timestamp.
- One log line per check: `CPU 3% (<10) | GPU 0% (<5, 5 samples, mem 12MB)`.
- `PATH` is extended with `$PATH:` first so tests can put mocks on it. Under cron behavior is unchanged.

## Tests (bats-core)

Mock `nvidia-smi` and `nebius` on `PATH`; temp config, state and log files. Cases: no GPU, one idle GPU, one busy GPU, multi-GPU with one busy, `nvidia-smi` failing, CPU busy with GPU idle, memory-held grace. Assert that `nebius ... stop` is never called when the GPU is busy or the check fails.

## CI and docs

- GitHub Actions: shellcheck + bats.
- Script passes shellcheck (including existing SC1090 and SC2155 warnings).
- README: how GPU detection works, new config rows, GPU testing section next to the CPU one, NVIDIA-only note, sampling limit.
