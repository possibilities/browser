#!/usr/bin/env bash
#
# e2e-test.sh — End-to-end test for the browser container.
#
# Tests the browser image in two modes: base (CDP only) and RDP-enabled
# (CDP + gnome-remote-desktop via ENABLE_RDP=true).
#
# Starts one or more containers of each mode, verifies that Chromium's
# CDP endpoint comes up, verifies the RDP port on RDP-enabled
# containers, uses agent-browser to load web pages, and asserts that the
# pages rendered correctly.  Cleans up containers on exit regardless of
# success or failure.
#
# Usage:
#   ./e2e-test.sh              # run with defaults (2 containers per mode)
#   ./e2e-test.sh 1            # run with 1 container per mode
#   ./e2e-test.sh 3            # run with 3 containers per mode
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
readonly BASE_PREFIX="e2e-browser-test"
readonly RDP_PREFIX="e2e-rdp-test"
readonly BASE_IMAGE="browser:test-latest"

readonly BASE_CDP_PORT=19222                   # base container CDP ports start here
readonly RDP_CDP_PORT=19322                    # RDP container CDP ports start here
readonly RDP_RDP_PORT=13389                    # RDP container RDP ports start here

readonly CONTAINER_CPUS=4
readonly CONTAINER_MEMORY="4G"
readonly CDP_WAIT_TIMEOUT=120                  # seconds to wait for CDP readiness
readonly SERVICE_WAIT_TIMEOUT=60               # seconds to wait for RDP readiness
readonly NUM_CONTAINERS="${1:-2}"               # default: 2 containers per mode

# Test targets — pages we'll load and the expected title substring
declare -a TEST_URLS=("https://example.com" "https://www.wikipedia.org")
declare -a TEST_TITLES=("Example Domain" "Wikipedia")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
pass() { printf '[%s] \033[32mPASS\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[%s] \033[31mFAIL\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

# ---------------------------------------------------------------------------
# Cleanup — runs on EXIT so containers are always removed
# ---------------------------------------------------------------------------
cleanup() {
    log "Cleaning up test containers …"
    for prefix in "$BASE_PREFIX" "$RDP_PREFIX"; do
        for i in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
            local name="${prefix}-${i}"
            container stop "$name"   2>/dev/null || true
            container delete "$name" 2>/dev/null || true
        done
    done
    # Clean up host-forward test container
    container stop "e2e-host-forward-test"   2>/dev/null || true
    container delete "e2e-host-forward-test" 2>/dev/null || true
    log "Removing test images …"
    container image remove "$BASE_IMAGE" 2>/dev/null || true
    log "Cleanup complete."
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pre-run cleanup (in case a previous run was interrupted)
# ---------------------------------------------------------------------------
log "Pre-run cleanup of any leftover test containers …"
cleanup  # trap is already set, so this is safe to call directly

# ---------------------------------------------------------------------------
# Build container images
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log "Building image ${BASE_IMAGE} …"
container build -t "$BASE_IMAGE" "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Start containers
# ---------------------------------------------------------------------------
for i in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
    name="${BASE_PREFIX}-${i}"
    port=$(( BASE_CDP_PORT + i ))
    log "Starting base container ${name} (CDP port ${port}) …"
    container run -d \
        --name "$name" \
        --cpus "$CONTAINER_CPUS" \
        --memory "$CONTAINER_MEMORY" \
        --publish "${port}:9222" \
        --tmpfs /dev/shm \
        -e CDP_BIND_ADDRESS=0.0.0.0 \
        -e ENABLE_RDP=false \
        "$BASE_IMAGE"
done

for i in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
    name="${RDP_PREFIX}-${i}"
    cdp_port=$(( RDP_CDP_PORT + i ))
    rdp_port=$(( RDP_RDP_PORT + i ))
    log "Starting RDP container ${name} (CDP ${cdp_port}, RDP ${rdp_port}) …"
    container run -d \
        --name "$name" \
        --cpus "$CONTAINER_CPUS" \
        --memory "$CONTAINER_MEMORY" \
        --publish "${cdp_port}:9222" \
        --publish "${rdp_port}:3389" \
        --tmpfs /dev/shm \
        -e CDP_BIND_ADDRESS=0.0.0.0 \
        "$BASE_IMAGE"
done

# ---------------------------------------------------------------------------
# Wait for CDP readiness on every container
# ---------------------------------------------------------------------------
wait_for_cdp() {
    local port="$1" name="$2" deadline
    deadline=$(( $(date +%s) + CDP_WAIT_TIMEOUT ))
    log "Waiting for CDP on port ${port} (${name}) …"
    while true; do
        if curl -sf "http://127.0.0.1:${port}/json/version" >/dev/null 2>&1; then
            log "CDP ready on port ${port}."
            return 0
        fi
        if (( $(date +%s) >= deadline )); then
            fail "CDP on port ${port} (${name}) did not become ready within ${CDP_WAIT_TIMEOUT}s"
            log "--- container logs for ${name} ---"
            container logs "$name" 2>&1 | tail -40 || true
            return 1
        fi
        sleep 2
    done
}

for i in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
    wait_for_cdp $(( BASE_CDP_PORT + i )) "${BASE_PREFIX}-${i}"
done

for i in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
    wait_for_cdp $(( RDP_CDP_PORT + i )) "${RDP_PREFIX}-${i}"
done

# ---------------------------------------------------------------------------
# Wait for RDP on RDP-enabled containers
# ---------------------------------------------------------------------------
wait_for_port() {
    local port="$1" name="$2" service="$3" deadline
    deadline=$(( $(date +%s) + SERVICE_WAIT_TIMEOUT ))
    log "Waiting for ${service} on port ${port} (${name}) …"
    while true; do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
            log "${service} ready on port ${port}."
            return 0
        fi
        if (( $(date +%s) >= deadline )); then
            fail "${service} on port ${port} (${name}) did not become ready within ${SERVICE_WAIT_TIMEOUT}s"
            log "--- container logs for ${name} ---"
            container logs "$name" 2>&1 | tail -40 || true
            return 1
        fi
        sleep 2
    done
}

FAILURES=0
TESTS_RUN=0

for i in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
    name="${RDP_PREFIX}-${i}"
    rdp_port=$(( RDP_RDP_PORT + i ))

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if wait_for_port "$rdp_port" "$name" "RDP"; then
        pass "[${name}] RDP listening on port ${rdp_port}"
    else
        FAILURES=$(( FAILURES + 1 ))
    fi
done

# ---------------------------------------------------------------------------
# Run page-load tests with agent-browser
# ---------------------------------------------------------------------------
run_page_tests() {
    local prefix="$1" base_port="$2" label="$3"

    for i in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
        local port=$(( base_port + i ))
        local name="${prefix}-${i}"
        local session="${prefix}-${i}"

        log "Connecting agent-browser to ${name} [${label}] (port ${port}) …"
        agent-browser connect "${port}" --session "$session"

        for t in "${!TEST_URLS[@]}"; do
            local url="${TEST_URLS[$t]}"
            local expected_title="${TEST_TITLES[$t]}"
            TESTS_RUN=$(( TESTS_RUN + 1 ))

            log "[${name}] Loading ${url} …"
            if ! agent-browser open "$url" --session "$session" 2>&1; then
                fail "[${name}] agent-browser open failed for ${url}"
                FAILURES=$(( FAILURES + 1 ))
                continue
            fi

            # Give the page a moment to settle
            agent-browser wait 2000 --session "$session" 2>/dev/null || true

            # Check the page title
            local title
            title="$(agent-browser get title --session "$session" 2>/dev/null || echo "")"
            if [[ "$title" == *"$expected_title"* ]]; then
                pass "[${name}] Title matches for ${url}: \"${title}\""
            else
                fail "[${name}] Title mismatch for ${url}: expected \"${expected_title}\", got \"${title}\""
                FAILURES=$(( FAILURES + 1 ))
                log "[${name}] Snapshot:"
                agent-browser snapshot --session "$session" 2>/dev/null | head -20 || true
            fi

            # Verify the accessibility tree has content (page actually rendered)
            local snapshot
            TESTS_RUN=$(( TESTS_RUN + 1 ))
            snapshot="$(agent-browser snapshot --session "$session" 2>/dev/null || echo "")"
            if [[ -n "$snapshot" && "$snapshot" != *"empty"* ]]; then
                pass "[${name}] Page rendered content for ${url}"
            else
                fail "[${name}] Page appears empty for ${url}"
                FAILURES=$(( FAILURES + 1 ))
            fi
        done
    done
}

log "===== Testing base image ====="
run_page_tests "$BASE_PREFIX" "$BASE_CDP_PORT" "base"

log "===== Testing RDP mode ====="
run_page_tests "$RDP_PREFIX" "$RDP_CDP_PORT" "rdp"

# ---------------------------------------------------------------------------
# Host forwarding test (conditional - only runs if host DNS is configured)
# ---------------------------------------------------------------------------
HOST_FORWARD_SKIPPED=false
if container system dns list 2>/dev/null | grep -q "host.container.internal"; then
    log "===== Testing host forwarding ====="

    # Use a unique high port to avoid conflicts with existing services
    HOST_TEST_PORT=19580
    HOST_FORWARD_CDP_PORT=19422

    echo "hello from host" > /tmp/host-test-index.html
    python3 -m http.server "$HOST_TEST_PORT" --directory /tmp --bind 127.0.0.1 &
    HOST_SERVER_PID=$!
    trap "kill $HOST_SERVER_PID 2>/dev/null || true; rm -f /tmp/host-test-index.html" EXIT
    sleep 1

    # Start a dedicated container configured with our test port for host forwarding
    name="e2e-host-forward-test"
    log "Starting host-forward test container ${name} (CDP ${HOST_FORWARD_CDP_PORT}) ..."
    container run -d \
        --name "$name" \
        --cpus "$CONTAINER_CPUS" \
        --memory "$CONTAINER_MEMORY" \
        --publish "${HOST_FORWARD_CDP_PORT}:9222" \
        --tmpfs /dev/shm \
        -e CDP_BIND_ADDRESS=0.0.0.0 \
        -e ENABLE_RDP=false \
        -e HOST_FORWARD_PORT="$HOST_TEST_PORT" \
        "$BASE_IMAGE"

    # Wait for CDP to be ready
    wait_for_cdp "$HOST_FORWARD_CDP_PORT" "$name"

    port="$HOST_FORWARD_CDP_PORT"
    session="host-forward-test"

    agent-browser connect "$port" --session "$session"

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    log "[${name}] Loading http://localhost:${HOST_TEST_PORT} (host forwarding) ..."

    if agent-browser open "http://localhost:${HOST_TEST_PORT}/host-test-index.html" --session "$session" 2>&1; then
        agent-browser wait 2000 --session "$session" 2>/dev/null || true
        snapshot="$(agent-browser snapshot --session "$session" 2>/dev/null || echo "")"

        if [[ "$snapshot" == *"hello from host"* ]]; then
            pass "[${name}] Host forwarding works - content loaded from host"
        else
            fail "[${name}] Host forwarding failed - content not from host"
            FAILURES=$(( FAILURES + 1 ))
        fi
    else
        fail "[${name}] Failed to load localhost URL"
        FAILURES=$(( FAILURES + 1 ))
    fi

    kill $HOST_SERVER_PID 2>/dev/null || true
else
    HOST_FORWARD_SKIPPED=true
    log "===== Skipping host forwarding test (host.container.internal DNS not configured) ====="
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
log "=============================="
log "  Tests run: ${TESTS_RUN}"
log "  Failures:  ${FAILURES}"
log "=============================="

if [[ "$HOST_FORWARD_SKIPPED" == "true" ]]; then
    echo ""
    printf '\033[33m==============================\033[0m\n'
    printf '\033[33m  HOST FORWARDING TEST SKIPPED\033[0m\n'
    printf '\033[33m  Run: sudo container system dns create host.container.internal --localhost 203.0.113.113\033[0m\n'
    printf '\033[33m==============================\033[0m\n'
fi

if (( FAILURES > 0 )); then
    fail "Some tests failed."
    exit 1
else
    pass "All tests passed!"
    exit 0
fi
