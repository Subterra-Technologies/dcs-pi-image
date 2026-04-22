#!/bin/bash -e
# Enable first-boot unit + heartbeat timer + the tailscaled daemon.
# SSH is key-only (also enforced by tag-level Tailscale SSH ACLs later).

systemctl enable first-boot.service
systemctl enable dcs-heartbeat.timer
systemctl enable unattended-upgrades.service
systemctl enable tailscaled.service
systemctl disable zabbix-proxy 2>/dev/null || true

sed -i \
    -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
    -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
    -e 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' \
    /etc/ssh/sshd_config

# Lock down SSH authorized_keys installed via rootfs overlay.
if [ -f /home/dcs/.ssh/authorized_keys ]; then
    chmod 0700 /home/dcs/.ssh
    chmod 0600 /home/dcs/.ssh/authorized_keys
    chown -R dcs:dcs /home/dcs/.ssh
fi

# ip_forward sysctl is already in /etc/sysctl.d/99-dcs.conf via the
# rootfs overlay — no additional writes needed here.
