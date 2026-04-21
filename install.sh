#!/usr/bin/env bash
# Detel Pi bootstrap — turn a fresh Raspberry Pi OS install into a Detel Pi.
#
# Fresh-Pi flow:
#   1. rpi-imager → Raspberry Pi OS Lite, Advanced options: set SSH pubkey, enable SSH
#   2. ssh <user>@<pi>.local
#   3. curl -fsSL http://<lan>:8000/install.sh | DETEL_SRC=http://<lan>:8000 sudo -E bash
#
# After install, detel-setup TUI launches automatically. Answer the prompts and
# the Pi joins the tailnet.
#
# DETEL_SRC can be either an HTTP(S) URL (LAN server) or a local repo checkout.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root (use sudo -E)"; exit 1; }

DETEL_SRC="${DETEL_SRC:-}"
[[ -n "${DETEL_SRC}" ]] || {
    echo "DETEL_SRC is required."
    echo "  URL form:   DETEL_SRC=http://<lan>:8000 sudo -E bash install.sh"
    echo "  Local form: DETEL_SRC=/path/to/detel-pi-image sudo -E bash install.sh"
    exit 1
}

fetch() {
    # fetch <repo-relative-path> <dest-absolute-path>
    local src_rel="$1" dst="$2"
    mkdir -p "$(dirname "${dst}")"
    if [[ "${DETEL_SRC}" =~ ^https?:// ]]; then
        curl -fsSL "${DETEL_SRC%/}/${src_rel}" -o "${dst}"
    else
        cp "${DETEL_SRC%/}/${src_rel}" "${dst}"
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

echo "==> [3/7] ensure 'detel' user"
if ! id -u detel >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo detel
    echo "  created user detel"
    # Copy SSH key from whoever invoked sudo, so ops can immediately ssh detel@...
    if [[ -n "${SUDO_USER:-}" ]] && [[ -f "/home/${SUDO_USER}/.ssh/authorized_keys" ]]; then
        install -d -m 0700 -o detel -g detel /home/detel/.ssh
        install -m 0600 -o detel -g detel "/home/${SUDO_USER}/.ssh/authorized_keys" \
            /home/detel/.ssh/authorized_keys
        echo "  copied SSH pubkey from ${SUDO_USER} → detel"
    fi
fi

echo "==> [4/7] harden sshd (key-only auth)"
sed -i \
    -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
    -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
    -e 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' \
    /etc/ssh/sshd_config
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

echo "==> [5/7] install detel scripts"
for script in detel-enroll detel-heartbeat detel-setup detel; do
    fetch "rootfs/usr/local/sbin/${script}" "/usr/local/sbin/${script}"
    chmod 0755 "/usr/local/sbin/${script}"
done

echo "==> [6/7] install systemd units"
for unit in first-boot.service detel-heartbeat.service detel-heartbeat.timer; do
    fetch "rootfs/etc/systemd/system/${unit}" "/etc/systemd/system/${unit}"
done
systemctl daemon-reload
systemctl enable tailscaled.service
systemctl enable first-boot.service
systemctl enable detel-heartbeat.timer 2>/dev/null || true

install -d -m 0755 /var/lib/detel

echo "==> [7/7] launching detel-setup TUI"
echo ""
exec /usr/local/sbin/detel-setup
