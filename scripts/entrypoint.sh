#!/bin/bash
set -euo pipefail

log() { echo "[entrypoint] $*"; }

# ---- directory setup --------------------------------------------------------
log "Ensuring runtime directories..."
mkdir -p /run/user/1000 /var/log/supervisord /home/browser/user-data
chown browser:browser /run/user/1000 /home/browser/user-data
chmod 700 /run/user/1000

# ---- conditionally disable RDP services --------------------------------------
if [ "${ENABLE_RDP:-}" = "false" ]; then
    log "RDP disabled (ENABLE_RDP=false), removing RDP services..."
    rm -f /etc/supervisor/conf.d/services/pipewire.conf \
          /etc/supervisor/conf.d/services/wireplumber.conf \
          /etc/supervisor/conf.d/services/gnome-remote-desktop.conf
else
    # /dev/fuse is only needed for gnome-remote-desktop clipboard support
    chmod 666 /dev/fuse 2>/dev/null || true

    # Write RDP credentials from env (default: browser/browser)
    local_user="${RDP_USERNAME:-browser}"
    local_pass="${RDP_PASSWORD:-browser}"
    creds_file="/home/browser/.local/share/gnome-remote-desktop/credentials.ini"
    cat > "$creds_file" <<CREDS
[RDP]
credentials={'username': <'${local_user}'>, 'password': <'${local_pass}'>}
CREDS
    chown browser:browser "$creds_file"
    chmod 600 "$creds_file"
    log "RDP credentials set (user=${local_user})"
fi

# ---- set up host.container.internal DNS for host forwarding ----------------
# Extract gateway IP from resolv.conf (the nameserver is the VM gateway)
gateway_ip=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)
if [ -n "$gateway_ip" ]; then
    log "Adding host.container.internal -> $gateway_ip to /etc/hosts"
    echo "$gateway_ip host.container.internal" >> /etc/hosts
fi

# ---- rebuild font cache for runtime-mounted fonts --------------------------
log "Rebuilding font cache..."
fc-cache -f

# ---- hand off to supervisord as PID 1 --------------------------------------
log "Starting supervisord (foreground)..."
exec supervisord -n -c /etc/supervisor/supervisord.conf
