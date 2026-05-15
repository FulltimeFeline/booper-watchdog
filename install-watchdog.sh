#!/usr/bin/env bash
#
# Booper watchdog installer.
#
# One-shot install for a per-host monitor that pings your phone via APNs
# whenever something on the server goes south (disk full, service down,
# load through the roof). Drops a watchdog script + systemd unit + timer
# in place and starts the timer.
#
# Run on your server:
#     curl -fsSL https://your-host/install-watchdog.sh | bash
#
# Or piped through SSH from your laptop:
#     ssh user@host 'bash -s' < install-watchdog.sh
#
# Requirements on the server:
#   - bash 4+
#   - systemd (any distro shipped after 2016 — Ubuntu 16.04+, Debian 9+,
#     Amazon Linux 2, Alpine 3.14+, etc.)
#   - `bot` CLI from Booper's Tier 1 install (snapshot.sh) OR a working
#     `bot notify --title T --body B` shim. The watchdog calls this when
#     a check fails. If `bot` isn't on PATH, alerts go to
#     ~/.booper/alerts.log only.
#
# What it monitors out of the box:
#   - Disk usage on /            > 90%
#   - Memory usage               > 90%
#   - Load average (1-min)       > 5x CPU count
#   - SSH service                must be active (sshd or ssh)
#
# Edit /usr/local/etc/booper-watchdog.conf to add more checks. Reruns of
# this installer are idempotent — your config is preserved.

set -euo pipefail

INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
WATCHDOG="$INSTALL_PREFIX/bin/booper-watchdog"
NOTIFY="$INSTALL_PREFIX/bin/booper-notify"
CONFIG="$INSTALL_PREFIX/etc/booper-watchdog.conf"
UNIT_DIR="/etc/systemd/system"
SERVICE="$UNIT_DIR/booper-watchdog.service"
TIMER="$UNIT_DIR/booper-watchdog.timer"
RELAY_URL="https://beepboop.fulltimefeline.com/notify"

need_root() {
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            echo "Re-running with sudo…" >&2
            exec sudo -E bash "$0" "$@"
        fi
        echo "This installer needs root (systemd units live in /etc/systemd/system)." >&2
        exit 1
    fi
}

need_root "$@"

echo "→ Writing $NOTIFY (shim to Booper push relay)"
install -d "$(dirname "$NOTIFY")"
cat > "$NOTIFY" <<NOTIFY
#!/usr/bin/env bash
# booper-notify — tiny relay client. Stores the device token Booper pushes
# in via SSH on first connect, then POSTs alerts to the Booper relay which
# forwards to APNs. Pure curl, no Python, no daemon.

set -euo pipefail

RELAY_URL="$RELAY_URL"
TOKEN_FILE="/var/lib/booper-watchdog/device-token"

cmd="\${1:-}"; shift || true
case "\$cmd" in
    register-device)
        token=""
        while [[ \$# -gt 0 ]]; do
            case "\$1" in
                --token) token="\$2"; shift 2;;
                *) shift;;
            esac
        done
        if [[ -z "\$token" ]]; then
            echo "missing --token" >&2; exit 2
        fi
        mkdir -p "\$(dirname "\$TOKEN_FILE")"
        printf '%s' "\$token" > "\$TOKEN_FILE"
        chmod 600 "\$TOKEN_FILE"
        echo "ok"
        ;;
    alert|notify)
        title=""; body=""; category=""; bot_id=""
        while [[ \$# -gt 0 ]]; do
            case "\$1" in
                --title)    title="\$2";    shift 2;;
                --body)     body="\$2";     shift 2;;
                --category) category="\$2"; shift 2;;
                --bot-id)   bot_id="\$2";   shift 2;;
                *) shift;;
            esac
        done
        if [[ ! -r "\$TOKEN_FILE" ]]; then
            echo "no device token registered yet (Booper sends it on first SSH connect)" >&2
            exit 1
        fi
        token=\$(cat "\$TOKEN_FILE")
        payload=\$(printf '{"token":"%s","title":"%s","body":"%s","host":"%s","category":"%s","botId":"%s"}' \\
            "\$token" "\${title//\\"/\\\\\\"}" "\${body//\\"/\\\\\\"}" "\$(hostname)" "\$category" "\$bot_id")
        curl -fsSL -X POST "\$RELAY_URL" \\
            -H "Content-Type: application/json" \\
            --data "\$payload" --max-time 10 > /dev/null
        ;;
    heartbeat)
        # Tiny "I'm alive" ping so the relay can fire a "server down" push
        # if it stops hearing from us. No-op silently if not registered.
        [[ -r "\$TOKEN_FILE" ]] || exit 0
        token=\$(cat "\$TOKEN_FILE")
        payload=\$(printf '{"token":"%s","host":"%s"}' "\$token" "\$(hostname)")
        # Strip /notify suffix to hit the sibling /heartbeat endpoint.
        heartbeat_url="\${RELAY_URL%/notify}/heartbeat"
        curl -fsSL -X POST "\$heartbeat_url" \\
            -H "Content-Type: application/json" \\
            --data "\$payload" --max-time 10 > /dev/null || true
        ;;
    *)
        echo "Usage: booper-notify {register-device --token HEX | alert --title T --body B | heartbeat}" >&2
        exit 2
        ;;
esac
NOTIFY
chmod +x "$NOTIFY"

echo "→ Writing $WATCHDOG"
install -d "$(dirname "$WATCHDOG")"
cat > "$WATCHDOG" <<'WATCHDOG'
#!/usr/bin/env bash
# Booper watchdog — runs every minute via systemd timer, fires `bot notify`
# whenever a check transitions from passing → failing. Per-check state is
# persisted in ~/.booper/state/ so we don't spam push notifications.

set -uo pipefail

CONFIG="/usr/local/etc/booper-watchdog.conf"
STATE_DIR="/var/lib/booper-watchdog"
LOG="$STATE_DIR/alerts.log"
mkdir -p "$STATE_DIR"

# Defaults — overridable via config.
DISK_PCT_MAX=90
MEM_PCT_MAX=90
LOAD_PER_CPU_MAX=5
WATCH_SERVICES="sshd"

if [[ -r "$CONFIG" ]]; then source "$CONFIG"; fi

notify() {
    local title="$1" body="$2"
    echo "$(date -Is) [$title] $body" >> "$LOG"
    # Preferred: Booper relay shim (POST to APNs gateway). Falls back to a
    # `bot notify` CLI if the user wired up their own APNs server-side.
    if command -v booper-notify >/dev/null 2>&1; then
        booper-notify alert --title "$title" --body "$body" 2>>"$LOG" || true
    elif command -v bot >/dev/null 2>&1; then
        bot notify --title "$title" --body "$body" 2>>"$LOG" || true
    fi
}

check_transition() {
    # Args: check-key, currently-failing-bool, title, body
    local key="$1" failing="$2" title="$3" body="$4"
    local state_file="$STATE_DIR/$key.state"
    local prev="ok"
    [[ -r "$state_file" ]] && prev=$(cat "$state_file")
    local current="ok"
    [[ "$failing" == "1" ]] && current="alert"
    if [[ "$prev" != "$current" ]]; then
        echo -n "$current" > "$state_file"
        if [[ "$current" == "alert" ]]; then
            notify "🚨 $title" "$body"
        else
            notify "✅ $title" "Recovered: $body"
        fi
    fi
}

# 1. Disk
disk_pct=$(df -P / | awk 'NR==2 {gsub("%",""); print $5}')
if (( disk_pct > DISK_PCT_MAX )); then
    check_transition disk 1 "Disk almost full" "/ is at ${disk_pct}% on $(hostname)"
else
    check_transition disk 0 "Disk almost full" "/ at ${disk_pct}%"
fi

# 2. Memory
if [[ -r /proc/meminfo ]]; then
    total=$(awk '/^MemTotal:/  {print $2}' /proc/meminfo)
    avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    if [[ -n "$total" && -n "$avail" && "$total" -gt 0 ]]; then
        used_pct=$(( (total - avail) * 100 / total ))
        if (( used_pct > MEM_PCT_MAX )); then
            check_transition mem 1 "Memory pressure" "${used_pct}% RAM used on $(hostname)"
        else
            check_transition mem 0 "Memory pressure" "${used_pct}% RAM used"
        fi
    fi
fi

# 3. Load average
if [[ -r /proc/loadavg ]]; then
    load1=$(awk '{print $1}' /proc/loadavg)
    cpus=$(nproc 2>/dev/null || echo 1)
    threshold=$(awk -v c="$cpus" -v m="$LOAD_PER_CPU_MAX" 'BEGIN { print c * m }')
    over=$(awk -v l="$load1" -v t="$threshold" 'BEGIN { print (l > t) ? 1 : 0 }')
    if [[ "$over" == "1" ]]; then
        check_transition load 1 "Load spike" "1-min load $load1 on $(hostname) (limit ${threshold})"
    else
        check_transition load 0 "Load spike" "1-min load $load1"
    fi
fi

# 4. Services
for svc in $WATCH_SERVICES; do
    if ! systemctl is-active --quiet "$svc"; then
        check_transition "svc-$svc" 1 "Service down" "$svc on $(hostname) is not active"
    else
        check_transition "svc-$svc" 0 "Service down" "$svc"
    fi
done

# Heartbeat — tells the relay we're alive. Relay times this out (>3 min
# silence) and fires a "Server down" push when it does. Closes the gap
# where the host is fully unreachable and the local watchdog can't run.
if command -v booper-notify >/dev/null 2>&1; then
    booper-notify heartbeat 2>>"$LOG" || true
fi
WATCHDOG
chmod +x "$WATCHDOG"

if [[ ! -f "$CONFIG" ]]; then
    echo "→ Writing default $CONFIG (edit to customize thresholds + services)"
    install -d "$(dirname "$CONFIG")"
    cat > "$CONFIG" <<'CONF'
# Booper watchdog — tunable thresholds. Override any of these.
# DISK_PCT_MAX=90
# MEM_PCT_MAX=90
# LOAD_PER_CPU_MAX=5
# WATCH_SERVICES="sshd nginx postgresql"
CONF
fi

echo "→ Writing $SERVICE"
cat > "$SERVICE" <<UNIT
[Unit]
Description=Booper server-health watchdog (one-shot check, fires push on transition)
After=network-online.target

[Service]
Type=oneshot
ExecStart=$WATCHDOG
Nice=10
UNIT

echo "→ Writing $TIMER"
cat > "$TIMER" <<'UNIT'
[Unit]
Description=Run booper-watchdog every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
UNIT

echo "→ Enabling timer"
systemctl daemon-reload
systemctl enable --now booper-watchdog.timer

echo
echo "✓ Booper watchdog installed and running."
echo
echo "    Config:  $CONFIG"
echo "    Log:     /var/lib/booper-watchdog/alerts.log"
echo "    Status:  systemctl status booper-watchdog.timer"
echo "    Run now: systemctl start booper-watchdog.service"
echo
echo "    Relay:   $RELAY_URL"
echo
echo "Booper will push your device token to this host the next time you open"
echo "its Server detail in the app. Until then, alerts are logged locally but"
echo "no push will fire (booper-notify needs the token first)."
