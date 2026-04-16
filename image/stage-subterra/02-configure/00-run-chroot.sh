#!/bin/bash -e
# Run inside the target chroot: enable units, harden SSH, install iptables rules dir.

systemctl enable first-boot.service
systemctl enable subterra-heartbeat.timer
systemctl enable unattended-upgrades.service
# zabbix-proxy ships installed but disabled; enable per-school when ready.
systemctl disable zabbix-proxy 2>/dev/null || true

# SSH: key-only, no root.
sed -i \
    -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
    -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
    -e 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' \
    /etc/ssh/sshd_config

install -d -m 0755 /etc/iptables
