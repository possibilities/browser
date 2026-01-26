#!/bin/bash
set -e

SUPERVISORD_CONF="/etc/supervisor/supervisord.conf"
WAYLAND_SOCKET_PATH="/run/user/1000/wayland-0"
CDP_PORT="${CDP_PORT:-9222}"

# ---- helpers ----------------------------------------------------------------
log() { echo "[entrypoint] $*"; }

wait_for_file() {
  local path="$1" label="$2" timeout="${3:-30}"
  log "Waiting for $label ($path)..."
  for i in $(seq 1 "$timeout"); do
    [ -e "$path" ] && { log "$label is ready."; return 0; }
    sleep 0.5
  done
  log "ERROR: $label did not appear within ${timeout}x0.5s."
  return 1
}

wait_for_socket() {
  local path="$1" label="$2" timeout="${3:-30}"
  log "Waiting for $label ($path)..."
  for i in $(seq 1 "$timeout"); do
    [ -S "$path" ] && { log "$label is ready."; return 0; }
    sleep 0.5
  done
  log "ERROR: $label socket did not appear within ${timeout}x0.5s."
  return 1
}

wait_for_port() {
  local port="$1" label="$2" timeout="${3:-100}"
  log "Waiting for $label on port $port..."
  for i in $(seq 1 "$timeout"); do
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then
      log "$label is ready on port $port."
      return 0
    fi
    sleep 0.2
  done
  log "ERROR: $label did not become available on port $port within ${timeout}x0.2s."
  return 1
}

# ---- directory setup --------------------------------------------------------
log "Ensuring runtime directories..."
mkdir -p /run/user/1000 /run/dbus /var/log/supervisord /home/browser/user-data
chown browser:browser /run/user/1000 /home/browser/user-data
chmod 700 /run/user/1000

# ---- cleanup handler --------------------------------------------------------
cleanup() {
  log "Shutting down..."
  supervisorctl -c "$SUPERVISORD_CONF" stop chromium || true
  supervisorctl -c "$SUPERVISORD_CONF" stop mutter || true
  supervisorctl -c "$SUPERVISORD_CONF" stop dbus || true
  kill "$(cat /var/run/supervisord.pid 2>/dev/null)" 2>/dev/null || true
}
trap cleanup TERM INT

# ---- start supervisord ------------------------------------------------------
log "Starting supervisord..."
supervisord -c "$SUPERVISORD_CONF"
wait_for_socket /var/run/supervisor.sock "supervisord socket" 30

# ---- start D-Bus ------------------------------------------------------------
log "Starting D-Bus..."
supervisorctl -c "$SUPERVISORD_CONF" start dbus
wait_for_socket /run/dbus/system_bus_socket "D-Bus system bus" 50

# ---- start Mutter (Wayland headless) ----------------------------------------
log "Starting Mutter (Wayland headless)..."
supervisorctl -c "$SUPERVISORD_CONF" start mutter
wait_for_socket "$WAYLAND_SOCKET_PATH" "Wayland compositor" 60

# ---- start Chromium ----------------------------------------------------------
log "Starting Chromium..."
supervisorctl -c "$SUPERVISORD_CONF" start chromium
wait_for_port "$CDP_PORT" "Chromium CDP" 100

log "All services ready. CDP available on port $CDP_PORT."

# Keep the container alive
wait
