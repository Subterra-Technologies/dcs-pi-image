# dcs-pi-image

Raspberry Pi 5 tooling for the DCS fleet. One Pi per school district, acting as a Tailscale subnet router for that district's LAN.

Companion repo: [`dcs-hub`](https://github.com/Subterra-Technologies/dcs-hub) (datacenter Zabbix-VM tooling).
Full ops docs: [`docs/OPS_RUNBOOK.md`](docs/OPS_RUNBOOK.md).

---

## What this is

Each Pi ships to a school with DCS installed. On first boot after enrollment it joins the tailnet with a tag-scoped pre-auth key, advertises the school's LAN subnet as a Tailscale route, and becomes reachable by its district's Zabbix VM in the DC. Operators never need to be physically at the school after provisioning.

## Quick start — fresh Pi

**No golden image needed.** Flash plain Raspberry Pi OS Lite with rpi-imager, set a user/password in the Advanced options, and run the installer.

1. **Flash** Raspberry Pi OS Lite (64-bit) to an NVMe or SD with **rpi-imager**. In **Advanced options**, set:
   - Hostname (anything; the TUI renames it later)
   - Username + password
   - SSH enabled (password auth is fine)
   - Wi-Fi / timezone / keyboard as needed
2. **Boot** the Pi on the office LAN with PoE+. SSH in with the user/password you set:
   ```
   ssh <user>@<pi>.local
   ```
3. **Clone and run the installer:**
   ```
   git clone https://github.com/Subterra-Technologies/dcs-pi-image /tmp/dcs
   sudo bash /tmp/dcs/install.sh
   ```
   The installer pulls `tailscale`, `gum`, and `jq`, creates the `dcs` user, installs the DCS binaries + systemd units, and launches `dcs-setup`.
4. **Answer the TUI prompts:**
   - **District slug** — e.g. `oakridge`
   - **School LAN CIDR** — e.g. `10.42.0.0/24` (ask district IT; this gets advertised as a Tailscale subnet route)
   - **Hostname** — blank = auto `<district>-pi-<short-serial>`
   - **Pre-auth key** — mint one in the Tailscale admin console with `Tags = tag:pi-<slug>`
5. The TUI writes the enrollment JSON, kicks `first-boot.service`, verifies the tag, and reboots.
6. **Power off**, ship it. At the school the Pi boots, picks up the LAN, and re-advertises the CIDR. Routes auto-approve via ACL.

## SSH access post-install

Password SSH stays enabled after install, so the user/password you set via rpi-imager keeps working. After the Pi joins the tailnet, prefer Tailscale SSH for day-to-day access — no keys to distribute:

```
tailscale ssh dcs@<hostname>
```

Root login is disabled (`PermitRootLogin no`).

## Day 2

On any enrolled Pi:

```
sudo dcs status       # enrollment state, routes, peers
sudo dcs stats        # uptime, load, temp, Zabbix proxy
sudo dcs logs         # pick a service, tail the journal
sudo dcs routes       # view/edit advertised subnets
sudo dcs reconfigure  # re-run setup (swap district or authkey)
sudo dcs reset        # logout + wipe local state
```

## Fallback — unattended JSON seeding

If you can't SSH to the Pi at flash time (bench provisioning, no office LAN), mount the boot partition and drop in `/boot/firmware/dcs-enroll.json` directly — `dcs-enroll` picks it up on first boot:

```json
{
  "authkey": "tskey-auth-...",
  "district": "<slug>",
  "advertise_routes": ["10.42.0.0/24"],
  "hostname": "<slug>-pi-main"
}
```

`authkey` + `district` required; `advertise_routes` and `hostname` optional.

## Advanced — build a golden image

For high-volume deploys, the `image/` directory has a pi-gen driver that bakes everything into a flashable `.img.xz` so the Pi comes up already enrolled-ready:

```
./image/build.sh            # reuses cached pi-gen
./image/build.sh --clean    # from scratch
```

Artifacts land in `./deploy/*.img.xz`. Most deployments don't need this — the clone-and-run flow above is simpler to iterate on.

## Repo layout

| Path | Purpose |
|---|---|
| `install.sh`                    | One-shot installer — run on a fresh Pi OS Lite. |
| `rootfs/usr/local/sbin/dcs-*`   | Runtime tools (`dcs`, `dcs-setup`, `dcs-enroll`, `dcs-heartbeat`). |
| `rootfs/etc/systemd/system/`    | `first-boot.service`, `dcs-heartbeat.{service,timer}`. |
| `image/`                        | pi-gen build driver + `stage-dcs` (advanced, golden-image path). |
| `docs/OPS_RUNBOOK.md`           | Architecture, onboarding, troubleshooting, verification. |
| `tests/`                        | Integration tests — run with `python3 tests/test_enroll_integration.py`. |

## What NOT to commit

The tree itself contains no secrets — safe to publish. Never commit:
- Raw pre-auth keys (`tskey-auth-...`)
- Customer-specific ACL policies, tailnet exports, or district names/CIDRs from live deployments
- `/etc/dcs.conf` (if you use the OAuth-creds install path)

The `.gitignore` already blocks `*.key`, `*.pem`, `deploy/*.img*`, and `work/` (pi-gen output).
