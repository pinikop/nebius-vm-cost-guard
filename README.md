# Nebius VM Cost Guard

Automatically shuts down idle Nebius VMs to save costs.

> ⚠️ **Disclaimer:** This tool adds a cost-protection layer but is not bulletproof. It may shut down your VM during active work if CPU and GPU usage look idle (e.g., waiting for I/O, light coding, or GPU work that falls between checks). Tune thresholds for your workload and save your work frequently.  
> **Use at your own risk** - the author is not responsible for data loss, interrupted work, or unexpected shutdowns.

## How It Works

Cost Guard monitors your Nebius VM's CPU and GPU usage via cron and automatically stops the instance when idle:

1. Cron runs the script every 5 minutes
2. Script checks 5-minute CPU load average (not instant - avoids false positives)
3. If CPU is below threshold, it also checks the GPU (when present), then tracks idle duration
4. When idle time exceeds threshold, looks up the VM's instance ID (from the instance metadata service unless `INSTANCE_ID` is set) and runs `nebius compute instance stop` via the Nebius CLI
5. VM shuts down and you stop paying

### GPU detection

The VM counts as idle only when both CPU and GPU are idle. CPU-only VMs behave as before.

- `nvidia-smi` is sampled `GPU_SAMPLES` times (default 5), `GPU_SAMPLE_INTERVAL` seconds apart (default 2). The maximum utilization over all samples and all GPUs is used; the GPU is idle if it is below `GPU_THRESHOLD` (default 5%).
- A busy GPU resets the idle timer. A failed check (`nvidia-smi` error, timeout, unparsable output, or invalid GPU settings) counts as active, logs an error, and also resets the timer. A failed check never causes a shutdown.
- `GPU_MONITORING`: `auto` (default) checks the GPU if `nvidia-smi` exists or the NVIDIA driver is loaded (if `nvidia-smi` is then missing, that is an error and the VM keeps running); `on` always checks it, and a missing `nvidia-smi` is an error that keeps the VM running; `off` ignores the GPU. Any other value acts like `on`.
- Memory option: set `GPU_MEMORY_THRESHOLD_MB` above 0 to give a GPU that is idle but holds at least that much memory (for example, a loaded model) a longer limit, `GPU_MEM_IDLE_THRESHOLD_SECONDS` (default 3600). The longer limit is never shorter than `IDLE_THRESHOLD_SECONDS`, is decided on each check, and memory never blocks shutdown forever.

Limits:
- NVIDIA GPUs only.
- GPUs that report `[N/A]` for utilization or memory (for example, some MIG or vGPU setups) are treated as active, so the VM is never stopped. Use `GPU_MONITORING="off"` if you want CPU-only detection there.
- Sampling covers about 8 seconds of each 5-minute check, so bursty GPU workloads (for example, inference with long gaps) can be missed. Tune the thresholds for your workload.
- `auto` falls back to CPU-only only when `nvidia-smi` is missing and no NVIDIA driver is loaded (`/proc/driver/nvidia` absent), such as a VM without a GPU or without the driver installed.

## Prerequisites

1. **Service account** with permissions to stop compute instances
   - Create service account in Nebius Console: [Service Account Guide](https://docs.nebius.com/iam/service-accounts/manage)
   - Grant it the `compute.instance-power-operator` role (View, View metadata, Start, Stop) for the project that contains the VM, or a broader role. See [Nebius IAM roles](https://docs.nebius.com/iam/authorization/roles).

2. **Nebius VM** with the service account attached: [Compute Documentation](https://docs.nebius.com/compute)
   - Preferred: attach the service account at VM creation (`--service-account-id`). The preinstalled Nebius CLI then authenticates automatically with the token at `/mnt/cloud-metadata/token`.
   - Existing VM without one: create a CLI profile for the service account using an authorized key. See [Nebius CLI on a VM](https://docs.nebius.com/cli/compute-vm).
   - Tested with Nebius CLI `0.12.287` (check with `nebius version`). The script logs a warning if the installed version differs.

3. **On the VM:** bash, cron, `curl` and `timeout` (coreutils), which most Linux distributions include. `nvidia-smi` is needed on GPU VMs (it comes with the NVIDIA driver). `flock` (util-linux) stops overlapping runs and `logger` adds syslog entries; both are optional, and the script works without them.

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
   sudo chown root:root /opt/cost-guard/config.env /opt/cost-guard/idle-guard.sh
   sudo chmod 644 /opt/cost-guard/config.env

   sudo touch /var/log/cost-guard.log
   sudo chmod 644 /var/log/cost-guard.log
   ```
   
   **Note:** The script runs as root and sources `config.env`, so keep both files root-owned and not writable by other users. Do not run it from a user-writable clone.

   **Note:** If you changed `LOG_FILE` or `STATE_FILE` paths in step 3, adjust the paths accordingly. The state directory is created automatically by the script.

5. Add cron job (checks every 5 minutes)
   ```bash
   (sudo crontab -l 2>/dev/null; echo "*/5 * * * * /opt/cost-guard/idle-guard.sh") | sudo crontab -
   ```

6. Verify installation
   ```bash
   sudo /opt/cost-guard/idle-guard.sh
   tail -5 /var/log/cost-guard.log

   # The instance ID lookup must print your VM's ID (needs curl)
   curl -s -H "Metadata: true" http://metadata.nebius.internal/v1/instance-data/id
   ```

   The script also checks the instance ID when idle tracking starts. If you see `Cannot determine a valid instance ID` in the log, set `INSTANCE_ID` in `config.env` (find it with `nebius compute instance list`).

   The log should contain no `ERROR` lines. See [Checking for problems](#checking-for-problems).

## Checking for problems

Cost Guard runs in the background, so errors are easy to miss. It never stops a VM because a check failed. For example, if `nvidia-smi` is missing or broken on a GPU VM, the VM is treated as busy and keeps running (and costing money) until you fix it. Check for errors:

```bash
grep -E 'ERROR|WARN' /var/log/cost-guard.log | tail
journalctl -t cost-guard -p err      # the same errors in syslog, if journald is used
```

Errors are also written to `/var/run/cost-guard/last_error`. The file exists only if the latest check logged an error, and the next clean check removes it. To see it when you log in over SSH (Ubuntu and Debian):

```bash
sudo tee /etc/update-motd.d/99-cost-guard > /dev/null <<'EOF'
#!/bin/sh
f=/var/run/cost-guard/last_error
if [ -f "$f" ]; then
    echo "Cost Guard: the last check reported errors. This VM may not stop when idle."
    cat "$f"
fi
EOF
sudo chmod +x /etc/update-motd.d/99-cost-guard
```

If you changed `STATE_FILE`, use its directory instead of `/var/run/cost-guard`. On other distributions, put the same check in `/etc/profile.d/cost-guard.sh`.

## Log rotation

The log grows by about 100 KB per day (one check every 5 minutes) and is not rotated. For long-running VMs, add a rule:

```bash
sudo tee /etc/logrotate.d/cost-guard > /dev/null <<'EOF'
/var/log/cost-guard.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF
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

3. Run the script and check the log. The line should show GPU usage above the threshold, followed by "Resetting idle timer" (or "System is active." if no timer was running), and no shutdown:
   ```bash
   sudo /opt/cost-guard/idle-guard.sh
   tail -5 /var/log/cost-guard.log
   ```

4. Stop the load. Within the next checks the log should show GPU usage below the threshold, idle tracking starting, and then the shutdown after `IDLE_THRESHOLD_SECONDS`.

5. To compare, set `GPU_MONITORING="off"`: the busy GPU is then ignored and the VM is stopped once the CPU has been idle for `IDLE_THRESHOLD_SECONDS` (the first idle check only starts the timer). **This stops the VM - save your work first.** Restore production values afterward.

## Configuration

**Important:** Default values are starting points. Tune them based on your specific workload and requirements.

Edit `config.env` to customize:

| Variable | Default | Description |
|----------|---------|-------------|
| `INSTANCE_ID` | empty | VM instance ID. Empty = auto-detect from the instance metadata service (requires `curl`). Set to override |
| `CPU_THRESHOLD` | `10` | CPU % below which VM is "idle" |
| `IDLE_THRESHOLD_SECONDS` | `1800` | Seconds idle before shutdown (30 min) |
| `MIN_UPTIME_SECONDS` | `600` | Min uptime before allowing shutdown (10 min) |
| `GPU_MONITORING` | `auto` | `auto`: check GPU if `nvidia-smi` exists or the NVIDIA driver is loaded; `on`: require `nvidia-smi`; `off`: CPU only |
| `GPU_THRESHOLD` | `5` | GPU % below which the GPU is "idle" |
| `GPU_SAMPLES` | `5` | `nvidia-smi` samples per check (max is used) |
| `GPU_SAMPLE_INTERVAL` | `2` | Seconds between samples |
| `GPU_MEMORY_THRESHOLD_MB` | `0` | GPU memory (MB) that earns the longer limit when the GPU is idle; `0` ignores memory |
| `GPU_MEM_IDLE_THRESHOLD_SECONDS` | `3600` | Idle limit used when memory is held (never below `IDLE_THRESHOLD_SECONDS`) |
| `LOG_FILE` | `/var/log/cost-guard.log` | Log file location |
| `STATE_FILE` | `/var/run/cost-guard/idle_since` | State tracking file |
| `ENABLED` | `true` | Set to `false` to disable without removing cron job |

Invalid values are handled safely. If `IDLE_THRESHOLD_SECONDS`, `CPU_THRESHOLD` or `MIN_UPTIME_SECONDS` is not a whole number, the script logs an ERROR and does nothing. Invalid GPU settings count as a failed GPU check, so the VM stays up.

## Development

```bash
shellcheck idle-guard.sh
bats tests/
```

Install bats-core from your distro (`sudo apt-get install bats`) or from [git](https://github.com/bats-core/bats-core). Tests use mock `nvidia-smi` and `nebius` commands, so no GPU or real VM is needed.
