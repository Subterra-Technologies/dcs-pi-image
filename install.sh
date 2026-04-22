#!/usr/bin/env bash
# DCS Pi bootstrap — turn a fresh Raspberry Pi OS install into a DCS Pi.
#
# Fresh-Pi flow:
#   1. rpi-imager → Raspberry Pi OS Lite, Advanced options: set SSH pubkey, enable SSH
#   2. ssh <user>@<pi>.local
#   3. curl -fsSL http://<lan>:8000/install.sh | DCS_SRC=http://<lan>:8000 sudo -E bash
#
# After install, dcs-setup TUI launches automatically. Answer the prompts and
# the Pi joins the tailnet.
#
# DCS_SRC can be either an HTTP(S) URL (LAN server) or a local repo checkout.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root (use sudo -E)"; exit 1; }

DCS_SRC="${DCS_SRC:-}"
[[ -n "${DCS_SRC}" ]] || {
    echo "DCS_SRC is required."
    echo "  URL form:   DCS_SRC=http://<lan>:8000 sudo -E bash install.sh"
    echo "  Local form: DCS_SRC=/path/to/dcs-pi-image sudo -E bash install.sh"
    exit 1
}

fetch() {
    # fetch <repo-relative-path> <dest-absolute-path>
    local src_rel="$1" dst="$2"
    mkdir -p "$(dirname "${dst}")"
    if [[ "${DCS_SRC}" =~ ^https?:// ]]; then
        curl -fsSL "${DCS_SRC%/}/${src_rel}" -o "${dst}"
    else
        cp "${DCS_SRC%/}/${src_rel}" "${dst}"
    fi
}

CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}")"

echo "==> [1/7] apt repos (Tailscale + Charm)"
install -d /usr/share/keyrings
if [ ! -f /usr/share/keyrings/tailscale-archive-keyring.gpg ]; then
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.noarmor.gpg" \
        > /usr/share/keyrings/tailscale-archive-keyring.gpg
fi
cat > /etc/apt/sources.list.d/tailscale.list <<EOF
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian ${CODENAME} main
EOF

if [ ! -f /usr/share/keyrings/charm-archive-keyring.gpg ]; then
    curl -fsSL https://repo.charm.sh/apt/gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/charm-archive-keyring.gpg
fi
cat > /etc/apt/sources.list.d/charm.list <<'EOF'
deb [signed-by=/usr/share/keyrings/charm-archive-keyring.gpg] https://repo.charm.sh/apt/ * *
EOF

echo "==> [2/7] apt install"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale gum jq

echo "==> [3/7] ensure 'dcs' user"
if ! id -u dcs >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo dcs
    echo "  created user dcs"
    # Copy SSH key from whoever invoked sudo, so ops can immediately ssh dcs@...
    if [[ -n "${SUDO_USER:-}" ]] && [[ -f "/home/${SUDO_USER}/.ssh/authorized_keys" ]]; then
        install -d -m 0700 -o dcs -g dcs /home/dcs/.ssh
        install -m 0600 -o dcs -g dcs "/home/${SUDO_USER}/.ssh/authorized_keys" \
            /home/dcs/.ssh/authorized_keys
        echo "  copied SSH pubkey from ${SUDO_USER} → dcs"
    fi
fi

echo "==> [4/7] harden sshd (key-only auth)"
sed -i \
    -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
    -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
    -e 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' \
    /etc/ssh/sshd_config
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

echo "==> [5/7] install dcs scripts"
for script in dcs-enroll dcs-heartbeat dcs-setup dcs; do
    fetch "rootfs/usr/local/sbin/${script}" "/usr/local/sbin/${script}"
    chmod 0755 "/usr/local/sbin/${script}"
done

echo "==> [6/7] install systemd units"
for unit in first-boot.service dcs-heartbeat.service dcs-heartbeat.timer; do
    fetch "rootfs/etc/systemd/system/${unit}" "/etc/systemd/system/${unit}"
done
systemctl daemon-reload
systemctl enable tailscaled.service
systemctl enable first-boot.service
systemctl enable dcs-heartbeat.timer 2>/dev/null || true

install -d -m 0755 /var/lib/dcs

echo "==> [7/7] launching dcs-setup TUI"
echo ""
exec /usr/local/sbin/dcs-setup
