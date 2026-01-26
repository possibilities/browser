#!/bin/bash
# setup-remote-desktop.sh — Build-time configuration for gnome-remote-desktop.
#
# Creates dconf settings, self-signed TLS certificates for RDP, and
# credential files for RDP authentication.  Runs during container
# image build (not at runtime).
#
# Default credentials:  RDP user "browser" password "browser"
set -euo pipefail

GRD_DIR="/home/browser/.local/share/gnome-remote-desktop"

# ---------------------------------------------------------------------------
# Self-signed TLS certificate for RDP
# ---------------------------------------------------------------------------
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -sha256 -days 3650 -nodes \
    -keyout "$GRD_DIR/rdp-tls.key" \
    -out "$GRD_DIR/rdp-tls.crt" \
    -subj "/CN=browser-container" 2>/dev/null

chown browser:browser "$GRD_DIR/rdp-tls.key" "$GRD_DIR/rdp-tls.crt"
chmod 600 "$GRD_DIR/rdp-tls.key"

# ---------------------------------------------------------------------------
# dconf system database — gnome-remote-desktop reads GSettings at runtime
# ---------------------------------------------------------------------------
mkdir -p /etc/dconf/profile /etc/dconf/db/local.d

cat > /etc/dconf/profile/user <<'PROFILE'
user-db:user
system-db:local
PROFILE

cat > /etc/dconf/db/local.d/remote-desktop <<'DCONF'
[org/gnome/desktop/remote-desktop/rdp]
enable=true
view-only=false
tls-cert='/home/browser/.local/share/gnome-remote-desktop/rdp-tls.crt'
tls-key='/home/browser/.local/share/gnome-remote-desktop/rdp-tls.key'
DCONF

dconf update

# ---------------------------------------------------------------------------
# Credentials — GKeyFile fallback (no GNOME Keyring / TPM in container)
# ---------------------------------------------------------------------------
# The headless daemon reads credentials.ini (not grd-credentials.ini)
# using GVariant format for the values.
# RDP: username "browser", password "browser"
cat > "$GRD_DIR/credentials.ini" <<'CREDS'
[RDP]
credentials={'username': <'browser'>, 'password': <'browser'>}
CREDS

chown browser:browser "$GRD_DIR/credentials.ini"
chmod 600 "$GRD_DIR/credentials.ini"
