# linux-host-health

Bash CLI that inspects one Linux host the way a data center tech does: load, memory, disk, failed systemd units, listeners, and recent auth failures. Optional `systemd` timer writes a log every 15 minutes.

This is the follow-on project to [Linux-Learning-Journey](https://github.com/winear86/Linux-Learning-Journey). Notes stay in that repo. Runnable ops work lives here.

`git pull` only updates these files from GitHub. `./check.sh` is what reads *this* machine.

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

Disk lines skip WSL helper mounts (`/mnt/wslg`, `/usr/lib/wsl`, kernel module paths, `/init`). `/` and `/mnt/c` still show.

Exit codes: `0` all pass, `1` warn, `2` fail, `3` usage error.

## Resume on an existing clone

```bash
cd ~/linux-host-health
git pull
./check.sh
./check.sh -j /tmp/host-health.json
./check.sh -q
```

## Quick start (first time)

```bash
git clone https://github.com/winear86/linux-host-health.git
cd linux-host-health
chmod +x check.sh
./check.sh
```

Run this on a machine you own. Do not point it at production systems you do not control.

## Config

Defaults live in `health.conf`.

```bash
./check.sh -c /etc/host-health.conf
```

## systemd timer

Meant for a real Linux VM or bare metal. WSL can run the CLI by hand; the timer is optional and often flaky there.

```bash
sudo mkdir -p /opt/linux-host-health /var/log
sudo cp -a check.sh health.conf /opt/linux-host-health/
sudo chmod +x /opt/linux-host-health/check.sh
sudo cp systemd/host-health.service systemd/host-health.timer /etc/systemd/system/
sudo touch /var/log/host-health.log
sudo systemctl daemon-reload
sudo systemctl enable --now host-health.timer
sudo systemctl start host-health.service
tail /var/log/host-health.log
```

## Sample output

See [samples/example-report.txt](samples/example-report.txt).

## Out of scope (v1)

No Slack/email alerts, no multi-host SSH fleet, no Prometheus exporter, no hardware SMART/memtest.
