#!/usr/bin/env bash
# DCS Pi bootstrap — turn a fresh Raspberry Pi OS Lite into a DCS Pi.
#
# Dead-simple flow:
#   1. Flash Raspberry Pi OS Lite (rpi-imager → Advanced options: set username,
#      password, hostname, and enable SSH).
#   2. Boot the Pi on the office LAN with PoE+. SSH in with your user/password.
#   3. Clone this repo and run the installer:
#        git clone https://github.com/Subterra-Technologies/dcs-pi-image /tmp/dcs
#        sudo bash /tmp/dcs/install.sh
#      Or, with OAuth auto-mint enabled:
#        export DCS_TS_OAUTH_CLIENT_ID=...
#        export DCS_TS_OAUTH_CLIENT_SECRET=...
#        sudo -E bash /tmp/dcs/install.sh
#
# After install, dcs-setup TUI launches automatically. Answer the prompts and
# the Pi joins the tailnet.
#
# Advanced: DCS_SRC can point at an HTTP(S) URL (LAN mirror) or an alternate
# local checkout. By default it's the directory this script lives in.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root (sudo -E bash install.sh)"; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DCS_SRC="${DCS_SRC:-${HERE}}"

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
    if [[ -n "${SUDO_USER:-}" ]] && [[ -f "/home/${SUDO_USER}/.ssh/authorized_keys" ]]; then
        install -d -m 0700 -o dcs -g dcs /home/dcs/.ssh
        install -m 0600 -o dcs -g dcs "/home/${SUDO_USER}/.ssh/authorized_keys" \
            /home/dcs/.ssh/authorized_keys
        echo "  copied SSH pubkey from ${SUDO_USER} → dcs"
    fi
fi

echo "==> [4/7] harden sshd (disable root login; password auth stays on)"
# Note: password auth is deliberately left enabled so operators can SSH in with
# the user/password they set via rpi-imager. Tailscale SSH is the primary
# access path post-enrollment; the LAN password path is a break-glass fallback.
sed -i -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

echo "==> [5/7] install dcs scripts"
for script in dcs-enroll dcs-heartbeat dcs-setup dcs; do
    fetch "rootfs/usr/local/sbin/${script}" "/usr/local/sbin/${script}"
    chmod 0755 "/usr/local/sbin/${script}"
done

# Optional: persist OAuth creds when provided at install time. The Pi-side
# dcs-setup doesn't use them today, but the file is the same shape the VM
# side reads, so it's one less thing to configure later.
if [[ -n "${DCS_TS_OAUTH_CLIENT_ID:-}" && -n "${DCS_TS_OAUTH_CLIENT_SECRET:-}" ]]; then
    umask 077
    cat > /etc/dcs.conf <<EOF
# Tailscale API creds. Scopes: devices:read, auth_keys:write.
DCS_TS_OAUTH_CLIENT_ID=${DCS_TS_OAUTH_CLIENT_ID}
DCS_TS_OAUTH_CLIENT_SECRET=${DCS_TS_OAUTH_CLIENT_SECRET}
DCS_TS_TAILNET=${DCS_TS_TAILNET:--}
EOF
    chmod 0600 /etc/dcs.conf
    echo "    wrote /etc/dcs.conf"
fi

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
