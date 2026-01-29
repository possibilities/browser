#!/bin/bash
set -euo pipefail

# Monitors CDP activity and shuts down container after idle timeout.
# Checks every second, prints every 10 seconds, kills after 10s idle.

ACTIVITY_FILE="${CDP_ACTIVITY_FILE:-/run/cdp-activity}"
IDLE_TIMEOUT_MS="${IDLE_TIMEOUT_MS:-10000}"
PRINT_INTERVAL="${IDLE_PRINT_INTERVAL:-10}"

echo "[idle-reporter] Monitoring $ACTIVITY_FILE (timeout: ${IDLE_TIMEOUT_MS}ms, print every ${PRINT_INTERVAL}s)"

check_count=0

while true; do
  if [ -f "$ACTIVITY_FILE" ]; then
    now=$(date +%s.%N)
    last=$(date -d "$(stat -c %y "$ACTIVITY_FILE")" +%s.%N)
    idle_ms=$(awk "BEGIN {printf \"%.0f\", ($now - $last) * 1000}")

    # Print every PRINT_INTERVAL seconds
    if [ $((check_count % PRINT_INTERVAL)) -eq 0 ]; then
      echo "idle for ${idle_ms}ms"
    fi

    # Shutdown if idle too long
    if [ "$idle_ms" -gt "$IDLE_TIMEOUT_MS" ]; then
      echo "[idle-reporter] Idle timeout exceeded (${idle_ms}ms > ${IDLE_TIMEOUT_MS}ms). Shutting down."
      # Stop supervisord gracefully (PID 1), which stops all services
      kill -TERM 1
      exit 0
    fi
  else
    if [ $((check_count % PRINT_INTERVAL)) -eq 0 ]; then
      echo "idle for unknown (no activity file)"
    fi
  fi

  check_count=$((check_count + 1))
  sleep 1
done
