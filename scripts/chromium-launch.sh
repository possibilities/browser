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

# ---- Flag validation ---------------------------------------------------------
BLOCKED_FLAG_PREFIXES=(
  --no-sandbox
  --disable-web-security
  --disable-setuid-sandbox
  --allow-running-insecure-content
  --remote-debugging-port
  --remote-debugging-address
  --user-data-dir
  --remote-allow-origins
)

validate_flag() {
  local flag="$1"
  if [[ "$flag" != --* ]]; then
    echo "[chromium-launch] WARNING: Rejected flag (missing -- prefix): $flag" >&2
    return 1
  fi
  local key="${flag%%=*}"
  for blocked in "${BLOCKED_FLAG_PREFIXES[@]}"; do
    if [ "$key" = "$blocked" ]; then
      echo "[chromium-launch] WARNING: Rejected blocked flag: $flag" >&2
      return 1
    fi
  done
  return 0
}

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
  for env_flag in "${ENV_FLAGS[@]}"; do
    validate_flag "$env_flag" && FLAGS+=("$env_flag")
  done
fi

# Merge flags from runtime flags file (JSON: { "flags": ["--flag1", "--flag2"] })
if [ -f "$RUNTIME_FLAGS_PATH" ]; then
  if ! FILE_FLAGS=$(jq -r '.flags[]? // empty' "$RUNTIME_FLAGS_PATH" 2>/dev/null); then
    echo "[chromium-launch] WARNING: Failed to parse $RUNTIME_FLAGS_PATH, skipping." >&2
  else
    while IFS= read -r flag; do
      [ -n "$flag" ] && validate_flag "$flag" && FLAGS+=("$flag")
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
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
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
