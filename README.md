# linux-host-health

Bash CLI that inspects one Linux host the way a data center tech does: load, memory, disk, failed systemd units, listeners, and recent auth failures. Optional `systemd` timer writes a log every 15 minutes.

This is the follow-on project to [Linux-Learning-Journey](https://github.com/winear86/Linux-Learning-Journey). Notes stay in that repo. Runnable ops work lives here.

## What it checks

| Check | PASS | WARN | FAIL |
| --- | --- | --- | --- |
| Identity / uptime | always informational | — | — |
| Load (1 min) | below `nproc * LOAD_WARN_MULT` | at warn multiple | at fail multiple |
| Memory | used % below warn | `MEM_WARN_PCT` | `MEM_FAIL_PCT` |
| Disks | used % below warn | `DISK_WARN_PCT` | `DISK_FAIL_PCT` |
| systemd | no failed units | systemctl missing | any failed unit |
| Listeners | `ss`/`netstat` list | tools missing | — |
| Auth | failed logins below threshold | at `AUTH_FAIL_WARN` | — |

Exit codes: `0` all pass, `1` warn, `2` fail, `3` usage error.

## Quick start

```bash
git clone https://github.com/winear86/linux-host-health.git
cd linux-host-health
chmod +x check.sh
./check.sh
./check.sh -j /tmp/host-health.json
./check.sh -q          # only WARN/FAIL lines
```

Run this on a machine you own (homelab VM, personal laptop Linux, throwaway cloud VM). Do not point it at production systems you do not control.

## Config

Defaults live in `health.conf`. Override:

```bash
./check.sh -c /etc/host-health.conf
HEALTH_CONF=/etc/host-health.conf ./check.sh
```

## systemd timer

Installs a oneshot service plus a 15-minute timer. Edit `WorkingDirectory` in the unit if you do not use `/opt/linux-host-health`.

```bash
sudo mkdir -p /opt/linux-host-health /var/log
sudo cp -a check.sh health.conf /opt/linux-host-health/
sudo chmod +x /opt/linux-host-health/check.sh
sudo cp systemd/host-health.service systemd/host-health.timer /etc/systemd/system/
sudo touch /var/log/host-health.log
sudo systemctl daemon-reload
sudo systemctl enable --now host-health.timer
sudo systemctl list-timers host-health.timer
sudo systemctl start host-health.service   # run once now
tail /var/log/host-health.log
```

Disable:

```bash
sudo systemctl disable --now host-health.timer
```

## Sample output

See [samples/example-report.txt](samples/example-report.txt).

## Layout

```
check.sh                  CLI
health.conf               thresholds
systemd/host-health.service
systemd/host-health.timer
samples/example-report.txt
```

## Out of scope (v1)

No Slack/email alerts, no multi-host SSH fleet, no Prometheus exporter. Those are v2 after this is stable on one box.

## License

Use and modify freely for personal labs and learning.
