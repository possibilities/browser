FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install all runtime dependencies in a single layer
RUN apt-get update && \
    apt-get -y --no-install-recommends install \
    # Wayland compositor (Mutter 43 requires XWayland)
    mutter \
    xwayland \
    # System bus (required by Mutter and Chromium)
    dbus \
    # Browser
    chromium \
    # Process management
    supervisor \
    # Anti-detection fonts
    fonts-liberation \
    fonts-noto-cjk \
    fonts-noto-color-emoji \
    fonts-nanum \
    fontconfig \
    # Utilities for readiness checks, process management, and port forwarding
    netcat-openbsd \
    procps \
    socat \
    && fc-cache -f \
    && rm -rf /var/lib/apt/lists/*

# Create unprivileged browser user
RUN useradd -m -s /bin/bash -u 1000 browser

# Pre-create runtime directories
RUN mkdir -p \
    /run/user/1000 \
    /run/dbus \
    /home/browser/user-data \
    /home/browser/.config/chromium \
    /home/browser/.pki/nssdb \
    /home/browser/.cache/dconf \
    /var/log/supervisord \
    /chromium \
    /tmp/.X11-unix \
    && chown -R browser:browser /run/user/1000 /home/browser \
    && chmod 700 /run/user/1000 \
    && chmod 1777 /tmp/.X11-unix

# Custom D-Bus config (avoids capability dropping unsupported in apple/container VMs)
COPY configs/dbus-system.conf /etc/dbus-1/container-system.conf

# Chromium managed policy (anti-detection settings)
RUN mkdir -p /etc/chromium/policies/managed
COPY configs/policy.json /etc/chromium/policies/managed/policy.json

# Chromium first-run preferences
COPY configs/master_preferences /etc/chromium/master_preferences

# Supervisor configuration
COPY configs/supervisord.conf /etc/supervisor/supervisord.conf
COPY services/ /etc/supervisor/conf.d/services/

# Scripts
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/chromium-launch.sh /usr/local/bin/chromium-launch.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/chromium-launch.sh

# Environment defaults
ENV WIDTH=1920
ENV HEIGHT=1080
ENV CDP_PORT=9222
ENV CDP_INTERNAL_PORT=9221

EXPOSE 9222

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
