#!/usr/bin/env bash
#
# e2e-test.sh — End-to-end test for the browser container.
#
# Starts one or more browser containers, verifies that Chromium's CDP
# endpoint comes up, uses agent-browser to load web pages, and asserts
# that the pages rendered correctly. Cleans up containers on exit
# regardless of success or failure.
#
# Usage:
#   ./e2e-test.sh              # run with defaults (2 containers)
#   ./e2e-test.sh 1            # run with 1 container
#   ./e2e-test.sh 3            # run with 3 containers
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
readonly PREFIX="e2e-browser-test"          # container name prefix (won't collide with normal use)
readonly IMAGE="browser:test-latest"
readonly BASE_PORT=19222                    # host ports start here (well above the default 9222)
readonly CONTAINER_CPUS=4
readonly CONTAINER_MEMORY="4G"
readonly CDP_WAIT_TIMEOUT=120              # seconds to wait for CDP readiness
readonly NUM_CONTAINERS="${1:-2}"           # default: 2 containers

# Test targets — pages we'll load and the expected title substring
declare -a TEST_URLS=("https://example.com" "https://www.wikipedia.org")
declare -a TEST_TITLES=("Example Domain" "Wikipedia")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
pass() { printf '[%s] \033[32mPASS\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[%s] \033[31mFAIL\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

container_name() { echo "${PREFIX}-${1}"; }
host_port()      { echo $(( BASE_PORT + $1 )); }

# ---------------------------------------------------------------------------
# Cleanup — runs on EXIT so containers are always removed
# ---------------------------------------------------------------------------
cleanup() {
    log "Cleaning up test containers …"
    for i in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
        local name
        name="$(container_name "$i")"
        # Stop then delete; ignore errors if container doesn't exist
        container stop "$name"   2>/dev/null || true
        container delete "$name" 2>/dev/null || true
    done
    log "Removing test image ${IMAGE} …"
    container image remove "$IMAGE" 2>/dev/null || true
    log "Cleanup complete."
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pre-run cleanup (in case a previous run was interrupted)
# ---------------------------------------------------------------------------
log "Pre-run cleanup of any leftover test containers …"
cleanup  # trap is already set, so this is safe to call directly

# ---------------------------------------------------------------------------
# Rebuild the container image
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log "Building container image ${IMAGE} …"
container build -t "$IMAGE" "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Start containers
# ---------------------------------------------------------------------------
for i in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
    name="$(container_name "$i")"
    port="$(host_port "$i")"
    log "Starting container ${name} (host port ${port}) …"
    container run -d \
        --name "$name" \
        --cpus "$CONTAINER_CPUS" \
        --memory "$CONTAINER_MEMORY" \
        --publish "${port}:9222" \
        --tmpfs /dev/shm \
        -e CDP_BIND_ADDRESS=0.0.0.0 \
        "$IMAGE"
done

# ---------------------------------------------------------------------------
# Wait for CDP readiness on every container
# ---------------------------------------------------------------------------
wait_for_cdp() {
    local port="$1" deadline name="$2"
    deadline=$(( $(date +%s) + CDP_WAIT_TIMEOUT ))
    log "Waiting for CDP on port ${port} (${name}) …"
    while true; do
        if curl -sf "http://127.0.0.1:${port}/json/version" >/dev/null 2>&1; then
            log "CDP ready on port ${port}."
            return 0
        fi
        if (( $(date +%s) >= deadline )); then
            fail "CDP on port ${port} (${name}) did not become ready within ${CDP_WAIT_TIMEOUT}s"
            # Dump logs for debugging
            log "--- container logs for ${name} ---"
            container logs "$name" 2>&1 | tail -40 || true
            return 1
        fi
        sleep 2
    done
}

for i in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
    wait_for_cdp "$(host_port "$i")" "$(container_name "$i")"
done

# ---------------------------------------------------------------------------
# Run page-load tests with agent-browser
# ---------------------------------------------------------------------------
FAILURES=0
TESTS_RUN=0

for i in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
    port="$(host_port "$i")"
    name="$(container_name "$i")"
    session="${PREFIX}-${i}"

    log "Connecting agent-browser to ${name} (port ${port}) …"
    agent-browser connect "${port}" --session "$session"

    for t in "${!TEST_URLS[@]}"; do
        url="${TEST_URLS[$t]}"
        expected_title="${TEST_TITLES[$t]}"
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
        title="$(agent-browser get title --session "$session" 2>/dev/null || echo "")"
        if [[ "$title" == *"$expected_title"* ]]; then
            pass "[${name}] Title matches for ${url}: \"${title}\""
        else
            fail "[${name}] Title mismatch for ${url}: expected \"${expected_title}\", got \"${title}\""
            FAILURES=$(( FAILURES + 1 ))
            # Grab a snapshot for debugging context
            log "[${name}] Snapshot:"
            agent-browser snapshot --session "$session" 2>/dev/null | head -20 || true
        fi

        # Verify the accessibility tree has content (page actually rendered)
        snapshot="$(agent-browser snapshot --session "$session" 2>/dev/null || echo "")"
        if [[ -n "$snapshot" && "$snapshot" != *"empty"* ]]; then
            pass "[${name}] Page rendered content for ${url}"
        else
            fail "[${name}] Page appears empty for ${url}"
            FAILURES=$(( FAILURES + 1 ))
        fi
    done
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
log "=============================="
log "  Tests run: ${TESTS_RUN}"
log "  Failures:  ${FAILURES}"
log "=============================="

if (( FAILURES > 0 )); then
    fail "Some tests failed."
    exit 1
else
    pass "All tests passed!"
    exit 0
fi
