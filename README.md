# browser-in-apple-container

Minimal ARM64 Chromium container for [apple/container](https://github.com/apple/container), exposing Chrome DevTools Protocol (CDP) on port 9222.

Uses Mutter as a headless Wayland compositor -- no X11 stack. Preserves anti-detection configs from onkernel's kernel-images.

## Architecture

```
apple/container micro-VM (arm64, Debian bookworm)
├── entrypoint.sh (bootstrap → exec supervisord)
└── supervisord (PID 1)
    ├── D-Bus session daemon
    ├── Mutter --wayland --headless --virtual-monitor 1920x1080
    ├── Chromium --remote-debugging-port=9221 (internal, localhost only)
    └── socat (forwards CDP_BIND_ADDRESS:9222 → 127.0.0.1:9221)
```

Startup order: D-Bus → Mutter (wait for D-Bus session socket) → Chromium (wait for Wayland socket) → socat (wait for internal CDP port).

## Requirements

- macOS 26+ (Tahoe) on Apple Silicon
- `container` CLI installed (see below)

### Installing `container`

1. Download the latest signed installer package from the [GitHub release page](https://github.com/apple/container/releases).
2. Double-click the `.pkg` file and follow the instructions. Enter your administrator password when prompted.
3. Start the system service:

```bash
container system start
```

To upgrade an existing install, stop and uninstall first (the `-k` flag keeps your data):

```bash
container system stop
/usr/local/bin/uninstall-container.sh -k
```

Then install the new package and run `container system start` again.

## Quick Start

```bash
# Build
container build -t browser:latest .

# Run
container run -d \
  --name browser \
  --cpus 4 \
  --memory 4G \
  --publish 9222:9222 \
  --tmpfs /dev/shm \
  browser:latest

# Verify CDP is working
curl http://127.0.0.1:9222/json/version
```

If port 9222 is already in use on the host (e.g., by Docker), change the host port:

```bash
container run -d \
  --name browser \
  --cpus 4 \
  --memory 4G \
  --publish 19222:9222 \
  --tmpfs /dev/shm \
  browser:latest

curl http://127.0.0.1:19222/json/version
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WIDTH` | `1920` | Virtual monitor width |
| `HEIGHT` | `1080` | Virtual monitor height |
| `CDP_PORT` | `9222` | Chrome DevTools Protocol port |
| `CDP_BIND_ADDRESS` | `127.0.0.1` | Address socat binds to for CDP (see [Security](#security)) |
| `CHROMIUM_FLAGS` | _(empty)_ | Additional Chromium flags (space-separated) |

### Runtime Flag Overlay

Mount a JSON file at `/chromium/flags` to inject flags at runtime:

```json
{ "flags": ["--disable-gpu", "--start-maximized"] }
```

```bash
container run -d \
  --name browser \
  --publish 9222:9222 \
  --tmpfs /dev/shm \
  -v /path/to/flags:/chromium/flags:ro \
  browser:latest
```

Flags are validated before being passed to Chromium:
- Each flag must begin with `--`
- Security-critical flags (`--no-sandbox`, `--disable-web-security`,
  `--remote-debugging-port`, etc.) are blocked
- Invalid JSON in the flags file is skipped with a warning

## Security

CDP is an unauthenticated protocol — anyone who can reach the port gets full browser control (arbitrary JS execution, cookie access, file reads). By default, socat binds to `127.0.0.1`, so CDP is only reachable from inside the VM and from the host via `--publish`.

**Do not set `CDP_BIND_ADDRESS=0.0.0.0` unless you understand the risk.** Binding to all interfaces exposes CDP to every peer on the network. If you need remote access, put an authenticating reverse proxy in front of the CDP port.

```bash
# Override bind address (NOT recommended for production)
container run -d \
  --name browser \
  -e CDP_BIND_ADDRESS=0.0.0.0 \
  --publish 9222:9222 \
  --tmpfs /dev/shm \
  browser:latest
```

## Profile Persistence

Browser state (cookies, localStorage, etc.) lives at `/home/browser/user-data`. Mount a volume to persist across restarts:

```bash
container run -d \
  --name browser \
  --publish 9222:9222 \
  --tmpfs /dev/shm \
  -v browser-data:/home/browser/user-data \
  browser:latest
```

## Connecting

### CDP Endpoint

```
http://127.0.0.1:9222
```

### Example: List Targets

```bash
curl -s http://127.0.0.1:9222/json/list | python3 -m json.tool
```

### Example: Browser Version

```bash
curl -s http://127.0.0.1:9222/json/version
```

### With agent-browser or Playwright

```javascript
const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
```

## Troubleshooting

### Check Logs

```bash
container exec browser cat /var/log/supervisord/mutter
container exec browser cat /var/log/supervisord/chromium
container exec browser cat /var/log/supervisord/dbus
```

### Mutter Fails to Start

If Mutter headless Wayland doesn't work (e.g., no GPU/render node in the VM), fall back to X11. See the "X11 Fallback" section below.

### CDP Unreachable

- Verify port mapping: `container run --publish 9222:9222`
- Check Chromium started: `container exec browser supervisorctl status`
- Check if Chromium is listening: `container exec browser socat -T1 /dev/null TCP:127.0.0.1:9222,connect-timeout=1 && echo open`

### X11 Fallback

If Wayland doesn't work in apple/container, switch to Xvfb + Mutter X11:

1. **Containerfile**: Add `xvfb x11-utils dbus-x11` to packages
2. **services/mutter.conf**: Change to `XDG_SESSION_TYPE=x11 mutter --replace --sm-disable` with `DISPLAY=:1`
3. **Add services/xvfb.conf**: `Xvfb :1 -screen 0 1920x1080x24`
4. **scripts/entrypoint.sh**: Add Xvfb start step, change readiness check to `xdpyinfo -display :1`
5. **scripts/chromium-launch.sh**: Remove `--ozone-platform=wayland`, add `export DISPLAY=:1`
