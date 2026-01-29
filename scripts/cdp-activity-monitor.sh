#!/bin/bash
set -euo pipefail

# Watches CDP traffic on loopback and touches activity file on each packet.
# This runs as a side observer - completely decoupled from the socat proxy.

ACTIVITY_FILE="${CDP_ACTIVITY_FILE:-/run/cdp-activity}"
CDP_INTERNAL_PORT="${CDP_INTERNAL_PORT:-9221}"

# Create initial activity file
touch "$ACTIVITY_FILE"

echo "[cdp-activity] Watching CDP traffic on port $CDP_INTERNAL_PORT"

# tcpdump on loopback, line-buffered output, touch file on each packet
exec tcpdump -i lo -l --immediate-mode "port $CDP_INTERNAL_PORT" 2>/dev/null | \
  while read -r _; do
    touch "$ACTIVITY_FILE"
  done
