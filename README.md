# Nebius VM Cost Guard

## Installation

1. Clone the repository
```bash
git clone https://github.com/pinikop/nebius-vm-cost-guard.git
cd nebius-vm-cost-guard
```

2. Edit idle-guard.sh and set your INSTANCE_ID (if hostname doesn't match)
```bash
nano idle-guard.sh
```

3. Copy script to system directory
```bash
sudo mkdir -p /opt/cost-guard
sudo cp idle-guard.sh /opt/cost-guard/idle-guard.sh
sudo chmod +x /opt/cost-guard/idle-guard.sh

sudo touch /var/log/cost-guard.log
sudo chmod 644 /var/log/cost-guard.log

(sudo crontab -l 2>/dev/null; echo "*/5 * * * * /opt/cost-guard/idle-guard.sh") | sudo crontab -

4. Test it
```bash
sudo /opt/cost-guard/idle-guard.sh
tail -5 /var/log/cost-guard.log
```
