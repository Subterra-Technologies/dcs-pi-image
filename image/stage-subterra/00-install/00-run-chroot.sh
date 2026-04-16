#!/bin/bash -e
# Add the Tailscale apt repo before 00-packages installs from it.

curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
    > /usr/share/keyrings/tailscale-archive-keyring.gpg

cat > /etc/apt/sources.list.d/tailscale.list <<'EOF'
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian bookworm main
EOF

apt-get update
