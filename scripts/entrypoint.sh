#!/bin/bash
set -euo pipefail

log() { echo "[entrypoint] $*"; }

# ---- directory setup --------------------------------------------------------
log "Ensuring runtime directories..."
mkdir -p /run/user/1000 /var/log/supervisord /home/browser/user-data
chown browser:browser /run/user/1000 /home/browser/user-data
chmod 700 /run/user/1000

# ---- rebuild font cache for runtime-mounted fonts --------------------------
log "Rebuilding font cache..."
fc-cache -f

# ---- hand off to supervisord as PID 1 --------------------------------------
log "Starting supervisord (foreground)..."
exec supervisord -n -c /etc/supervisor/supervisord.conf
