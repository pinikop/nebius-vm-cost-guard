# Pre-release checklist

These checks need a real Nebius VM and could not be run during development (the test suite uses mocks). Run them once on a throwaway GPU VM before relying on Cost Guard. Optionally repeat steps 1-5 and 9-10 on a CPU-only VM.

Setup:
- Create the VM with a service account attached that may stop instances (`--service-account-id`).
- Install Cost Guard as described in the README.
- Do not use a VM that holds work you care about. Steps 9-11 stop it.

## Environment

1. **CLI version.** Run `nebius version`. Record the output. The script compares its first line with `TESTED_NEBIUS_VERSION` (0.12.287) and logs a WARN if they differ. If the format is not a bare version number, fix the comparison.
2. **Authentication.** Run `nebius compute instance list` without logging in. It should work through the token at `/mnt/cloud-metadata/token`.
3. **Instance ID endpoint.** Run `curl -s -H "Metadata: true" http://metadata.nebius.internal/v1/instance-data/id`. The output must be the bare ID, equal to this VM's ID in `nebius compute instance list`. Quotes or JSON make the script reject it, so adjust the lookup if so.
4. **Cron environment.** Install the cron job, then check `sudo grep -E 'ERROR|WARN' /var/log/cost-guard.log` after the first idle check. There should be no `nebius CLI not found` error. Also run `sudo -i command -v nebius nvidia-smi curl timeout` to see where root finds each tool.
5. **State directory.** `/var/run/cost-guard/idle_since` keeps its value between cron runs. After a reboot it is gone, and `MIN_UPTIME_SECONDS` prevents an early stop.

## GPU

6. **`nvidia-smi` output.** Run `nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits`. Every GPU line must be two integers. A GPU that prints `[N/A]` is treated as busy.
7. **Busy GPU is never stopped.** Run the README's GPU testing steps with a GPU load running. The log shows `GPU usage` above the threshold, and the VM is not stopped. On a multi-GPU VM, load only one GPU.
8. **Auto detection under cron.** With `GPU_MONITORING="auto"`, the cron-run log shows `GPU usage:` on each line.

## Shutdown

9. **Manual stop.** Run `nebius compute instance stop --id <ID>` by hand last, since it stops the VM. Note that it blocks until the VM is stopped, then start the VM again.
10. **Full cycle.** Use test thresholds (README Testing section) with an idle VM. The VM stops after the idle limit. After you start it again, the next check does not stop it early.
11. **Missing permission.** Remove the stop permission (the `compute.instance-power-operator` role or equivalent) from the service account and repeat step 10. The log shows `Nebius CLI command failed`, the VM stays up, and the check keeps retrying.

## Visibility

12. **Error reporting.** Force an error (for example `GPU_MONITORING="on"` with a missing `nvidia-smi`, or an invalid `IDLE_THRESHOLD_SECONDS`) and run the script once. Check the log, `journalctl -t cost-guard -p err`, and `/var/run/cost-guard/last_error`.
13. **Login banner.** Install the banner from the README, then log in again over SSH. The error text appears. After a clean run the file is gone and the banner is silent.

## Cleanup

14. Restore production values in `config.env` and the 5-minute cron interval, or delete the throwaway VM.
