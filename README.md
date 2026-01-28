# browser-in-apple-container

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

## Security

CDP is unauthenticated. By default it binds to `127.0.0.1`. Do not bind to `0.0.0.0` without an authenticating reverse proxy.

## Acknowledgements

Built on ideas from [kernel-images](https://github.com/onkernel/kernel-images). See [NOTICES](./NOTICES).
