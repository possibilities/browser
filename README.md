# browser

Anti-detection Chromium container for [apple/container](https://github.com/apple/container) on Apple Silicon.

## Requirements

- macOS 26+ on Apple Silicon
- [`container` CLI](https://github.com/apple/container/releases) installed and running (`container system start`)

## Quick Start

```bash
container build -t browser:latest .

container run -d \
  --name browser \
  --cpus 4 \
  --memory 4G \
  --publish 9222:9222 \
  --tmpfs /dev/shm \
  browser:latest

curl http://127.0.0.1:9222/json/version
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WIDTH` | `1920` | Virtual monitor width |
| `HEIGHT` | `1080` | Virtual monitor height |
| `CDP_BIND_ADDRESS` | `127.0.0.1` | CDP bind address |
| `CHROMIUM_FLAGS` | _(empty)_ | Extra Chromium flags |
| `ENABLE_RDP` | `true` | RDP server on port 3389 |
| `RDP_USERNAME` | `browser` | RDP username |
| `RDP_PASSWORD` | `browser` | RDP password |
| `HOST_FORWARD_ENABLED` | `true` | Forward localhost to host |
| `HOST_FORWARD_PORT` | `8080` | Port to forward to host |

## Host Forwarding

The container can access services running on the host's localhost (e.g., a dev server on port 8080). Chrome inside the container can navigate to `http://localhost:8080` and reach your Mac.

### Quick Setup

Run once to create the DNS mapping:

```bash
sudo container system dns create host.container.internal --localhost 203.0.113.113
```

That's it. The container's socat forwarder (enabled by default) handles the rest.

### Automated Setup (recommended)

To persist this across reboots, create a LaunchAgent.

**1. Add sudoers entry** (allows the script to run without password):

```bash
sudo tee /etc/sudoers.d/container-dns > /dev/null <<'EOF'
%admin ALL=(ALL) NOPASSWD: /usr/local/bin/container system dns create *
%admin ALL=(ALL) NOPASSWD: /usr/local/bin/container system dns delete *
EOF
sudo chmod 440 /etc/sudoers.d/container-dns
```

**2. Create the setup script** at `~/.local/bin/container-host-dns`:

```bash
#!/bin/bash
set -euo pipefail
sudo container system dns create host.container.internal --localhost 203.0.113.113 2>/dev/null || true
```

Make it executable: `chmod +x ~/.local/bin/container-host-dns`

**3. Create the LaunchAgent** at `~/Library/LaunchAgents/local.container-host-dns.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.container-host-dns</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/YOUR_USERNAME/.local/bin/container-host-dns</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/container-host-dns.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/container-host-dns.log</string>
</dict>
</plist>
```

**4. Load the agent:**

```bash
launchctl load ~/Library/LaunchAgents/local.container-host-dns.plist
```

### How It Works

1. `container system dns create` creates a DNS entry mapping `host.container.internal` to a special IP (203.0.113.113)
2. Apple Container routes traffic to that IP back to the host's localhost
3. Inside the container, a socat forwarder listens on `127.0.0.1:8080` and forwards to `host.container.internal:8080`
4. Chrome accesses `localhost:8080` -> socat -> `host.container.internal:8080` -> host's `localhost:8080`

### Verify Setup

Check if DNS is configured:

```bash
container system dns list
# Should show: host.container.internal
```

### Change Port

```bash
container run -d --name browser -p 9222:9222 -e HOST_FORWARD_PORT=3000 browser:latest
```

### Disable Host Forwarding

```bash
container run -d --name browser -p 9222:9222 -e HOST_FORWARD_ENABLED=false browser:latest
```

## Security

CDP is unauthenticated. By default it binds to `127.0.0.1`. Do not bind to `0.0.0.0` without an authenticating reverse proxy.

## Acknowledgements

Built on ideas from [kernel-images](https://github.com/onkernel/kernel-images). See [NOTICES](./NOTICES).
