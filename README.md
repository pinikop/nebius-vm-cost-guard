# Nebius VM Cost Guard

Automatically shuts down idle Nebius VMs to save costs.

> ⚠️ **Disclaimer:** This tool adds a cost-protection layer but is not bulletproof. It may shut down your VM during active work if CPU usage patterns look idle (e.g., waiting for I/O, light coding). Tune thresholds for your workload and save your work frequently.  
> **Use at your own risk** - the author is not responsible for data loss, interrupted work, or unexpected shutdowns.

## How It Works

Cost Guard monitors your Nebius VM's CPU and GPU usage via cron and automatically stops the instance when idle:

1. Cron runs the script every 5 minutes
2. Script checks 5-minute CPU load average (not instant - avoids false positives)
3. If CPU is below threshold, it also checks the GPU (when present), then tracks idle duration
4. When idle time exceeds threshold, runs `nebius compute instance stop` via the Nebius CLI
5. VM shuts down and you stop paying

### GPU detection

The VM counts as idle only when both CPU and GPU are idle. CPU-only VMs behave as before.

- `nvidia-smi` is sampled `GPU_SAMPLES` times (default 5), `GPU_SAMPLE_INTERVAL` seconds apart (default 2). The maximum utilization over all samples and all GPUs is used; the GPU is idle if it is below `GPU_THRESHOLD` (default 5%).
- A busy GPU resets the idle timer. A failed check (`nvidia-smi` error, timeout, unparsable output, or invalid GPU settings) counts as active, logs an error, and also resets the timer. A failed check never causes a shutdown.
- `GPU_MONITORING`: `auto` (default) checks the GPU only if `nvidia-smi` exists; `on` always checks it, and a missing `nvidia-smi` is an error that keeps the VM running; `off` ignores the GPU. Any other value acts like `on`.
- Memory option: set `GPU_MEMORY_THRESHOLD_MB` above 0 to give a GPU that is idle but holds at least that much memory (for example, a loaded model) a longer limit, `GPU_MEM_IDLE_THRESHOLD_SECONDS` (default 3600). The longer limit is never shorter than `IDLE_THRESHOLD_SECONDS`, is decided on each check, and memory never blocks shutdown forever.

Limits:
- NVIDIA GPUs only.
- Sampling covers about 8 seconds of each 5-minute check, so bursty GPU workloads (for example, inference with long gaps) can be missed. Tune the thresholds for your workload.
- In `auto` mode a GPU VM silently falls back to CPU-only if `nvidia-smi` is not on `PATH`. Set `GPU_MONITORING="on"` to make that an error that keeps the VM running.

## Prerequisites

1. **Service account** with permissions to stop compute instances
   - Create service account in Nebius Console: [Service Account Guide](https://docs.nebius.com/iam/service-accounts/manage)
   - Add to a group with editor/admin permissions (or grant `compute.instances.update` permission)

2. **Nebius VM** with the service account attached: [Compute Documentation](https://docs.nebius.com/compute)
   - Preferred: attach the service account at VM creation (`--service-account-id`). The preinstalled Nebius CLI then authenticates automatically with the token at `/mnt/cloud-metadata/token`.
   - Existing VM without one: create a CLI profile for the service account using an authorized key. See [Nebius CLI on a VM](https://docs.nebius.com/cli/compute-vm).
   - Tested with Nebius CLI `0.12.287` (check with `nebius version`). The script logs a warning if the installed version differs.

## Installation

1. Start your Nebius VM (via Nebius Console or Nebius CLI) and ssh into it

2. Clone the repository
   ```bash
   git clone https://github.com/pinikop/nebius-vm-cost-guard.git
   cd nebius-vm-cost-guard
   ```

3. Configure settings (optional)
   ```bash
   nano config.env
   ```
   
   Customize thresholds, instance ID, and paths as needed.

4. Copy files to system directory
   ```bash
   sudo mkdir -p /opt/cost-guard
   sudo cp config.env idle-guard.sh /opt/cost-guard/
   sudo chmod +x /opt/cost-guard/idle-guard.sh

   sudo touch /var/log/cost-guard.log
   sudo chmod 644 /var/log/cost-guard.log
   ```
   
   **Note:** If you changed `LOG_FILE` or `STATE_FILE` paths in step 3, adjust the paths accordingly. The state directory is created automatically by the script.

5. Add cron job (checks every 5 minutes)
   ```bash
   (sudo crontab -l 2>/dev/null; echo "*/5 * * * * /opt/cost-guard/idle-guard.sh") | sudo crontab -
   ```

6. Verify installation
   ```bash
   sudo /opt/cost-guard/idle-guard.sh
   tail -5 /var/log/cost-guard.log
   ```

## Testing

To verify Cost Guard works without waiting 30 minutes, temporarily use shorter thresholds:

1. Edit config.env for testing:
   ```bash
   sudo nano /opt/cost-guard/config.env
   ```
   
   Change to test values:
   ```bash
   CPU_THRESHOLD=100            # Everything is "idle"
   IDLE_THRESHOLD_SECONDS=60    # 1 minute
   MIN_UPTIME_SECONDS=60        # 1 minute
   ```

2. Update cron to check every minute:
   ```bash
   sudo crontab -e
   ```
   
   Change the line from:
   ```
   */5 * * * * /opt/cost-guard/idle-guard.sh
   ```
   
   To:
   ```
   */1 * * * * /opt/cost-guard/idle-guard.sh
   ```

3. Monitor the logs:
   ```bash
   tail -f /var/log/cost-guard.log
   ```
   
   You should see idle shutdown trigger after ~1-2 minute.

4. **Important:** After testing, restore production values (or any other mode you want to use):
   ```bash
   sudo nano /opt/cost-guard/config.env
   # Change back to: CPU_THRESHOLD=10, IDLE_THRESHOLD_SECONDS=1800, MIN_UPTIME_SECONDS=600
   ```
   
   And restore cron interval:
   ```bash
   sudo crontab -e
   # Change back from: */1 * * * * /opt/cost-guard/idle-guard.sh
   # To:              */5 * * * * /opt/cost-guard/idle-guard.sh
   ```

## GPU testing

Run these on a VM with an NVIDIA GPU, after the CPU test above.

1. Add GPU test values to `/opt/cost-guard/config.env` (keep the CPU test values from above):
   ```bash
   GPU_THRESHOLD=5
   GPU_SAMPLES=3
   GPU_SAMPLE_INTERVAL=1
   ```

2. Start a GPU load and confirm `nvidia-smi` shows utilization above the threshold. For example, with PyTorch:
   ```bash
   python3 -c "
   import torch
   x = torch.randn(8192, 8192, device='cuda')
   while True:
       x = x @ x
       x /= x.norm()
   "
   ```
   Or use [gpu-burn](https://github.com/wilicc/gpu-burn).

3. Run the script and check the log. The line should show GPU usage above the threshold, followed by "Resetting idle timer", and no shutdown:
   ```bash
   sudo /opt/cost-guard/idle-guard.sh
   tail -5 /var/log/cost-guard.log
   ```

4. Stop the load. Within the next checks the log should show GPU usage below the threshold, idle tracking starting, and then the shutdown after `IDLE_THRESHOLD_SECONDS`.

5. To compare, set `GPU_MONITORING="off"`: the busy GPU is then ignored and the VM is stopped as soon as the CPU is idle. Restore production values afterward.

## Configuration

**Important:** Default values are starting points. Tune them based on your specific workload and requirements.

Edit `config.env` to customize:

| Variable | Default | Description |
|----------|---------|-------------|
| `INSTANCE_ID` | `$(hostname)` | Your VM instance ID |
| `CPU_THRESHOLD` | `10` | CPU % below which VM is "idle" |
| `IDLE_THRESHOLD_SECONDS` | `1800` | Seconds idle before shutdown (30 min) |
| `MIN_UPTIME_SECONDS` | `600` | Min uptime before allowing shutdown (10 min) |
| `GPU_MONITORING` | `auto` | `auto`: check GPU if `nvidia-smi` exists; `on`: require it; `off`: CPU only |
| `GPU_THRESHOLD` | `5` | GPU % below which the GPU is "idle" |
| `GPU_SAMPLES` | `5` | `nvidia-smi` samples per check (max is used) |
| `GPU_SAMPLE_INTERVAL` | `2` | Seconds between samples |
| `GPU_MEMORY_THRESHOLD_MB` | `0` | GPU memory (MB) that earns the longer limit when the GPU is idle; `0` ignores memory |
| `GPU_MEM_IDLE_THRESHOLD_SECONDS` | `3600` | Idle limit used when memory is held (never below `IDLE_THRESHOLD_SECONDS`) |
| `LOG_FILE` | `/var/log/cost-guard.log` | Log file location |
| `STATE_FILE` | `/var/run/cost-guard/idle_since` | State tracking file |
| `ENABLED` | `true` | Set to `false` to disable without removing cron job |

## Development

```bash
shellcheck idle-guard.sh
bats tests/
```

Install bats-core from your distro (`sudo apt-get install bats`) or from [git](https://github.com/bats-core/bats-core). Tests use mock `nvidia-smi` and `nebius` commands, so no GPU or real VM is needed.
