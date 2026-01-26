#!/bin/bash
set -euo pipefail

log() { echo "[profile-loader] $*"; }

# ---- copy host Chrome profile into container user-data ----------------------
if [ -d /mnt/host-profile ]; then
    log "Copying host Chrome profile to /home/browser/user-data..."
    cp -a /mnt/host-profile/. /home/browser/user-data/

    # Remove lock files that would block startup
    rm -f /home/browser/user-data/SingletonLock \
          /home/browser/user-data/SingletonSocket \
          /home/browser/user-data/SingletonCookie

    # Fix ownership for the browser user (UID 1000)
    chown -R browser:browser /home/browser/user-data
    log "Profile loaded successfully."
else
    log "No host profile found at /mnt/host-profile, using default."
fi

# ---- fix gnome-remote-desktop HOME env (missing from supervisor conf) -------
GRD_CONF="/etc/supervisor/conf.d/services/gnome-remote-desktop.conf"
if [ -f "$GRD_CONF" ]; then
    log "Patching gnome-remote-desktop supervisor config with HOME..."
    sed -i 's|environment=|environment=HOME="/home/browser",|' "$GRD_CONF"
fi

# ---- delegate to the real entrypoint ----------------------------------------
exec /usr/local/bin/entrypoint.sh
