# Nebius VM Cost Guard

Automatically shuts down idle Nebius VMs to save costs.

> ⚠️ **Disclaimer:** This tool adds a cost-protection layer but is not bulletproof. It may shut down your VM during active work if CPU usage patterns look idle (e.g., waiting for I/O, light coding). Tune thresholds for your workload and save your work frequently.  
> **Use at your own risk** - the author is not responsible for data loss, interrupted work, or unexpected shutdowns.

## How It Works

Cost Guard monitors your Nebius VM's CPU usage via cron and automatically stops the instance when idle:

1. Cron runs the script every minute
2. Script checks 5-minute CPU load average (not instant - avoids false positives)
3. If CPU is below threshold, tracks idle duration
4. When idle time exceeds threshold, sends stop command via Nebius CLI
5. VM shuts down and you stop paying

## Prerequisites

1. **Service account** with permissions to stop compute instances
   - Create service account in Nebius Console: [Service Account Guide](https://docs.nebius.com/iam/service-accounts/manage)
   - Add to a group with editor/admin permissions (or grant `compute.instances.update` permission)

2. **Nebius VM** created with the service account attached: [Compute Documentation](https://docs.nebius.com/compute)
   - Service account must be attached during VM creation
   - Cannot be added to existing VM

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

## Configuration

**Important:** Default values are starting points. Tune them based on your specific workload and requirements.

Edit `config.env` to customize:

| Variable | Default | Description |
|----------|---------|-------------|
| `INSTANCE_ID` | `$(hostname)` | Your VM instance ID |
| `CPU_THRESHOLD` | `10` | CPU % below which VM is "idle" |
| `IDLE_THRESHOLD_SECONDS` | `1800` | Seconds idle before shutdown (30 min) |
| `MIN_UPTIME_SECONDS` | `600` | Min uptime before allowing shutdown (10 min) |
| `LOG_FILE` | `/var/log/cost-guard.log` | Log file location |
| `STATE_FILE` | `/var/run/cost-guard/idle_since` | State tracking file |
