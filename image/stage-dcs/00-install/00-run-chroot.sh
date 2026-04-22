#!/bin/bash -e
# Add the Tailscale + Charm (gum) apt repos before 00-packages installs from them.

curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
    > /usr/share/keyrings/tailscale-archive-keyring.gpg

cat > /etc/apt/sources.list.d/tailscale.list <<'EOF'
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian bookworm main
EOF

curl -fsSL https://repo.charm.sh/apt/gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/charm-archive-keyring.gpg

cat > /etc/apt/sources.list.d/charm.list <<'EOF'
deb [signed-by=/usr/share/keyrings/charm-archive-keyring.gpg] https://repo.charm.sh/apt/ * *
EOF

apt-get update
