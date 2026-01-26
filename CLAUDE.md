# CLAUDE.md

## Fast container browser

- Target platform is `apple/container` on Apple Silicon (ARM64). Do not add x86-specific dependencies or workarounds.
- Keep the image minimal. Use `debian:bookworm-slim`. Install only `--no-install-recommends` packages. Never add build tools, compilers, or dev headers.
- Single `RUN` layer for all `apt-get install` packages. Clean `/var/lib/apt/lists/*` in the same statement.
- Do not add services beyond the existing four (dbus, mutter, chromium, socat). Any new process must be a supervisord program with priority ordering and a readiness gate.
- Do not remove or weaken the startup readiness gates (D-Bus socket → Wayland socket → CDP port → socat).
- supervisord is PID 1. Do not replace it.

## Anti-detection

Do not remove or weaken any of the following. They exist to defeat automation detection.

- Never remove `--disable-blink-features=AutomationControlled`. This suppresses `navigator.webdriver=true` and is the single most visible automation signal.
- Never remove `--force-webrtc-ip-handling-policy=disable_non_proxied_udp`. This prevents WebRTC IP leaks.
- Never change `--ozone-platform=wayland` to `--headless` or remove it. Chromium must run on a real Wayland compositor so screen dimensions, `window.outerHeight`, and GPU renderer strings look normal.
- Keep `--start-maximized`. Unusual viewport sizes are a fingerprinting signal.
- Do not remove any font packages (`fonts-liberation`, `fonts-noto-cjk`, `fonts-noto-color-emoji`, `fonts-nanum`, `fontconfig`). Missing fonts cause detectable gaps in `document.fonts.check()` and canvas fingerprinting. If adding fonts, prefer `fonts-noto-*`.
- Do not re-enable `PasswordManagerEnabled`, `AutofillCreditCardEnabled`, `TranslateEnabled`, or notifications in `policy.json`.
- Do not switch the default search provider away from DuckDuckGo.
- Do not re-enable Safe Browsing or DNS prefetching in `master_preferences`. Both create detectable network traffic patterns.
- Do not replace Mutter/Wayland with Xvfb unless Wayland is broken. X11 fallback is a last resort.

## Security

- Chromium runs as unprivileged user `browser` (UID 1000), never root.
- Never weaken the blocked-flag list in `chromium-launch.sh` (`--no-sandbox`, `--disable-web-security`, `--remote-debugging-port`, etc.).
- CDP binds to `127.0.0.1` by default. Do not change the default to `0.0.0.0`.
- Never add `--no-sandbox` or `--disable-setuid-sandbox` to any flag list.
