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
   - **OAuth client** (first Pi on this image only) — client ID + client secret from https://login.tailscale.com/admin/settings/oauth with scopes `devices:read` and `auth_keys:write`. Stored at `/etc/dcs.conf` and reused on subsequent setups.
   - **District slug** — e.g. `oakridge`
   - **School LAN CIDRs** — if another Pi is already enrolled in this district, its advertised routes auto-populate and you can accept them with a keystroke. Otherwise type the CIDR, e.g. `10.42.0.0/24`.
   - **Hostname** — auto-suggests the next free letter (`<slug>-pi-a`, `-b`, `-c`, …); blank accepts the suggestion.
   - **Auth key** — minted automatically via `dcs-mint-key` using your OAuth creds. No paste needed.
5. The TUI writes the enrollment JSON, kicks `first-boot.service`, verifies the tag, and reboots.
6. **Power off**, ship it. At the school the Pi boots, picks up the LAN, and re-advertises the CIDR. Routes auto-approve via ACL.

**Prerequisite in Tailscale ACL:** `tag:pi-<slug>` must be declared in `tagOwners` (and ideally `autoApprovers` for the CIDR range) before the first Pi in a district enrolls, otherwise `dcs-mint-key` gets rejected.

**Pre-baking OAuth creds:** if you build a custom image, set `DCS_TS_OAUTH_CLIENT_ID` / `DCS_TS_OAUTH_CLIENT_SECRET` before running `install.sh` (use `sudo -E`) and the TUI skips the OAuth prompt. For a one-off bypass with an already-minted key, export `DCS_AUTHKEY=tskey-auth-…` — the TUI uses it directly and skips both the OAuth prompt and the mint call.

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
| `rootfs/usr/local/sbin/dcs-*`   | Runtime tools (`dcs`, `dcs-setup`, `dcs-enroll`, `dcs-heartbeat`, `dcs-query`, `dcs-districts`, `dcs-mint-key`). |
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
