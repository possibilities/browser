#!/bin/bash
set -euo pipefail

USER_DATA_DIR="/home/browser/user-data"
RUNTIME_FLAGS_PATH="${RUNTIME_FLAGS_PATH:-/chromium/flags}"
# Chromium binds to 127.0.0.1 only (Debian ignores --remote-debugging-address).
# socat handles forwarding from 0.0.0.0:CDP_PORT to this internal port.
CDP_INTERNAL_PORT="${CDP_INTERNAL_PORT:-9221}"

# ---- Clean up stale lock files from previous SIGKILL termination ------------
rm -f "$USER_DATA_DIR/SingletonLock" \
      "$USER_DATA_DIR/SingletonSocket" \
      "$USER_DATA_DIR/SingletonCookie"

# ---- Kill any existing chromium processes for clean restart ------------------
pkill -9 -x chromium 2>/dev/null || true
# Wait briefly for processes to die
for i in $(seq 1 20); do
  pgrep -x chromium >/dev/null 2>&1 || break
  sleep 0.1
done

# ---- Build flag list --------------------------------------------------------
# Hard-coded flags (always present)
FLAGS=(
  --ozone-platform=wayland
  --remote-debugging-port="$CDP_INTERNAL_PORT"
  --remote-allow-origins=*
  --user-data-dir="$USER_DATA_DIR"
  --password-store=basic
  --no-first-run
  --disable-dev-shm-usage
  --start-maximized
  --disable-blink-features=AutomationControlled
  --force-webrtc-ip-handling-policy=disable_non_proxied_udp
)

# Merge flags from CHROMIUM_FLAGS environment variable
if [ -n "${CHROMIUM_FLAGS:-}" ]; then
  read -ra ENV_FLAGS <<< "$CHROMIUM_FLAGS"
  FLAGS+=("${ENV_FLAGS[@]}")
fi

# Merge flags from runtime flags file (JSON: { "flags": ["--flag1", "--flag2"] })
if [ -f "$RUNTIME_FLAGS_PATH" ]; then
  CONTENT=$(cat "$RUNTIME_FLAGS_PATH")
  if [ -n "$CONTENT" ]; then
    # Parse JSON flags array using sed/grep (no jq dependency)
    # Extracts strings between quotes from the "flags" array
    FILE_FLAGS=$(echo "$CONTENT" | \
      sed -n 's/.*"flags"\s*:\s*\[\(.*\)\].*/\1/p' | \
      tr ',' '\n' | \
      sed -n 's/.*"\([^"]*\)".*/\1/p')
    while IFS= read -r flag; do
      [ -n "$flag" ] && FLAGS+=("$flag")
    done <<< "$FILE_FLAGS"
  fi
fi

# Deduplicate flags (preserve first occurrence)
declare -A SEEN
UNIQUE_FLAGS=()
for flag in "${FLAGS[@]}"; do
  # Use the flag key (before =) for deduplication
  key="${flag%%=*}"
  if [ -z "${SEEN[$key]:-}" ]; then
    SEEN[$key]=1
    UNIQUE_FLAGS+=("$flag")
  fi
done

echo "CHROMIUM_FLAGS: ${UNIQUE_FLAGS[*]}"

# ---- Set up Wayland environment ---------------------------------------------
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket
export XDG_CONFIG_HOME=/home/browser/.config
export XDG_CACHE_HOME=/home/browser/.cache
export HOME=/home/browser

# ---- Wait for Wayland compositor --------------------------------------------
WAYLAND_SOCKET_PATH="${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}"
echo "[chromium-launch] Waiting for Wayland socket ($WAYLAND_SOCKET_PATH)..."
for i in $(seq 1 60); do
  [ -S "$WAYLAND_SOCKET_PATH" ] && break
  sleep 0.5
done
if [ ! -S "$WAYLAND_SOCKET_PATH" ]; then
  echo "[chromium-launch] ERROR: Wayland socket not found after 30s."
  exit 1
fi
echo "[chromium-launch] Wayland compositor is ready."

# ---- Launch Chromium as unprivileged user -----------------------------------
exec runuser -u browser -- chromium "${UNIQUE_FLAGS[@]}"
