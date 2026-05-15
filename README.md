# booper-watchdog

A tiny systemd-timer-driven health watchdog for any Linux host. Pings your
phone via APNs whenever the box goes off the rails — disk full, service
crashed, load spike — and again when it recovers. No daemon, no Go binary,
no third-party endpoint. Pure bash plus one curl call to the open-source
[booper-relay](https://github.com/fulltimefeline/booper-relay).

Designed as the optional push backend for the
Booper iOS app,
which can't run background SSH while it's closed (iOS doesn't allow it),
so the watchdog runs the polling on the server side and only wakes your
phone when something has actually changed state.

## What it monitors out of the box

| Check                | Default threshold       |
|----------------------|-------------------------|
| Disk usage on `/`    | warn above 90%          |
| Memory usage         | warn above 90%          |
| Load average (1-min) | warn above `5 × ncpu`   |
| Service liveness     | `sshd` must be active   |
| Reachability         | heartbeat to the relay; relay fires "server down" after ~3 min of silence |

Every check is a transition watcher: it only alerts when state flips
(`ok → alert` or `alert → recovered`). No flapping spam, no per-minute
duplicates.

## Install

One-liner, run on the server:

```bash
curl -fsSL https://raw.githubusercontent.com/fulltimefeline/booper-watchdog/main/install-watchdog.sh | sudo bash
```

Or paste-from-app: open Booper, tap a server, tap *Install Watchdog*.
The script the app shows is identical to the one in this repo — auditable
byte-for-byte before you run it.

## What it installs

```
/usr/local/bin/booper-watchdog          # the periodic check script
/usr/local/bin/booper-notify            # the relay client (register device, send alert, heartbeat)
/usr/local/etc/booper-watchdog.conf     # editable thresholds
/var/lib/booper-watchdog/               # state directory (per-check ok/alert files, alert log)
/etc/systemd/system/booper-watchdog.timer    # runs every 60s
/etc/systemd/system/booper-watchdog.service  # ExecStart=/usr/local/bin/booper-watchdog
```

The installer is **idempotent**. Rerun it any time without losing your
config or device token.

## Configure

Edit `/usr/local/etc/booper-watchdog.conf` to adjust thresholds or add
services to watch:

```bash
DISK_PCT_MAX=85
MEM_PCT_MAX=90
LOAD_PER_CPU_MAX=4
WATCH_SERVICES="sshd nginx postgresql redis"
```

Changes take effect on the next timer tick (within 60s). No reload needed
unless you edit the systemd unit itself.

## Operational reference

```bash
# Status
systemctl status booper-watchdog.timer
systemctl list-timers | grep booper

# Force a check right now
systemctl start booper-watchdog.service

# Watch the alert log
tail -f /var/lib/booper-watchdog/alerts.log

# Disable temporarily
systemctl stop booper-watchdog.timer

# Permanently remove
systemctl disable --now booper-watchdog.timer
rm /etc/systemd/system/booper-watchdog.{service,timer}
rm /usr/local/bin/booper-{watchdog,notify}
rm -rf /var/lib/booper-watchdog
```

## How notifications reach your phone

```
booper-watchdog (bash, runs every 60s)
    │
    ├── on state transition →
    │       booper-notify alert --title T --body B
    │           │
    │           └── HTTPS POST to https://beepboop.fulltimefeline.com/notify
    │                    (or your self-hosted booper-relay)
    │                       │
    │                       └── APNs → your iPhone
    │
    └── always →
            booper-notify heartbeat
                │
                └── HTTPS POST to /heartbeat
                    relay's timeout monitor fires "server down" alerts
                    after ~3 min of missing heartbeats
```

The Booper iOS app pushes its APNs device token to the server over SSH
when you first open a server's detail view. That's the only thing the app
itself does for push — every alert from then on originates on the server.

## Self-hosting the relay

Don't trust `beepboop.fulltimefeline.com`? Run your own. The relay is
~150 lines, open source, dockerized:

```bash
git clone https://github.com/booper-app/booper-relay
cd booper-relay
docker compose up -d
```

Then set the watchdog's `RELAY_URL` to point at your instance:

```bash
sudo sed -i 's|RELAY_URL=.*|RELAY_URL="https://relay.example.com/notify"|' /usr/local/bin/booper-notify
```

…and in Booper iOS: **Settings → Developer → Relay → Custom URL**.

## Requirements

- `bash` 4+
- `systemd` (any distro shipped after 2016 — Ubuntu 18.04+, Debian 10+,
  RHEL/CentOS 7+, Amazon Linux 2/2023, Fedora, Arch, Alpine with the
  systemd init)
- `curl`
- A working public-internet route to the relay (port 443 outbound)

## Privacy

The watchdog stores **only** your APNs device token at
`/var/lib/booper-watchdog/device-token` (mode 0600, root-only). It does
not phone home, does not collect telemetry, does not exfiltrate hostnames
to anywhere other than the relay you configured. The relay itself does
not persist any data beyond the in-memory heartbeat clock; see its README.

## License

MIT. See `LICENSE`.
