# Nebius VM Cost Guard

Automatically shuts down idle Nebius VMs to save costs.

## Installation

1. Clone the repository
```bash
git clone https://github.com/pinikop/nebius-vm-cost-guard.git
cd nebius-vm-cost-guard
```

2. Configure settings (optional)
```bash
nano config.env
```

Customize thresholds, instance ID, and paths as needed.

3. Copy files to system directory
```bash
sudo mkdir -p /opt/cost-guard
sudo cp config.env idle-guard.sh /opt/cost-guard/
sudo chmod +x /opt/cost-guard/idle-guard.sh

sudo touch /var/log/cost-guard.log
sudo chmod 644 /var/log/cost-guard.log
```

4. Add cron job
```bash
(sudo crontab -l 2>/dev/null; echo "*/5 * * * * /opt/cost-guard/idle-guard.sh") | sudo crontab -
```

5. Test it
```bash
sudo /opt/cost-guard/idle-guard.sh
tail -5 /var/log/cost-guard.log
```

## Configuration

Edit `config.env` to customize:

| Variable | Default | Description |
|----------|---------|-------------|
| `INSTANCE_ID` | `$(hostname)` | Your VM instance ID |
| `CPU_THRESHOLD` | `10` | CPU % below which VM is "idle" |
| `IDLE_THRESHOLD_SECONDS` | `1800` | Seconds idle before shutdown (30 min) |
| `MIN_UPTIME_SECONDS` | `600` | Min uptime before allowing shutdown (10 min) |
| `LOG_FILE` | `/var/log/cost-guard.log` | Log file location |
| `STATE_FILE` | `/var/run/cost-guard/idle_since` | State tracking file |
