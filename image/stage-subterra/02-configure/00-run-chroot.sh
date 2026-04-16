#!/bin/bash -e
# Enable first-boot unit + heartbeat timer + the tailscaled daemon.
# SSH is key-only (also enforced by tag-level Tailscale SSH ACLs later).

systemctl enable first-boot.service
systemctl enable subterra-heartbeat.timer
systemctl enable unattended-upgrades.service
systemctl enable tailscaled.service
systemctl disable zabbix-proxy 2>/dev/null || true

sed -i \
    -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
    -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
    -e 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' \
    /etc/ssh/sshd_config

# ip_forward sysctl is already in /etc/sysctl.d/99-subterra.conf via the
# rootfs overlay — no additional writes needed here.
