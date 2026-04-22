# dcs-pi-image

Raspberry Pi 5 golden image for the DCS fleet. One Pi per school district, acting as a Tailscale subnet router for that district's LAN.

Companion repo: [`dcs-hub`](https://github.com/Subterra-Technologies/dcs-hub) (datacenter Zabbix-VM tooling).
Full ops docs: [`docs/OPS_RUNBOOK.md`](docs/OPS_RUNBOOK.md).

---

## What this is

Each Pi ships to a school with a pre-flashed image and a pre-seeded enrollment JSON. On first boot it joins the tailnet with a tag-scoped pre-auth key, advertises the school's LAN subnet as a Tailscale route, and becomes reachable by its district's Zabbix VM in the DC. Operators never need to be physically at the school after provisioning.

## Quick start — provisioning a Pi in the office

1. **Flash** the latest `dcs-pi` image to an NVMe via USB M.2 dock. Build locally with `./image/build.sh` or grab the latest `.img.xz` from `./deploy/` after a build.
2. **Boot** the Pi on the office LAN with PoE+. Your ops SSH pubkey is baked into the image:
   ```bash
   ssh dcs@dcs-pi.local
   ```
3. **Run the TUI:**
   ```bash
   sudo dcs-setup
   ```
   Answer:
   - **District slug** — e.g. `oakridge` (lowercase, no spaces)
   - **School LAN CIDR** — e.g. `10.42.0.0/24` (ask district IT; this gets advertised as a Tailscale subnet route)
   - **Hostname** — blank defaults to `<district>-pi-<short-serial>`
   - **Pre-auth key** — mint one in the Tailscale admin console with `Tags = tag:pi-<slug>`
4. The TUI writes `/boot/firmware/dcs-enroll.json`, triggers `first-boot.service` (runs `dcs-enroll`), verifies the assigned tag, and reboots.
5. **Power off** with `sudo poweroff` and ship it. At the school the Pi boots, picks up the school's primary subnet, and re-advertises the pre-declared CIDR. Routes auto-approve via ACL `autoApprovers`.

## Building the image

```bash
cd dcs-pi-image
./image/build.sh              # reuses cached pi-gen
./image/build.sh --clean      # from scratch
```

Artifacts land in `./deploy/*.img.xz`. Docker is recommended; the build driver uses `build-docker.sh` when Docker is available.

## Fallback — unattended JSON seeding

If you can't SSH to the Pi (no office LAN at flash time, bench provisioning), mount the boot partition and drop in `/boot/firmware/dcs-enroll.json` directly:

```json
{
  "authkey": "tskey-auth-...",
  "district": "<slug>",
  "advertise_routes": ["10.42.0.0/24"],
  "hostname": "<slug>-pi-main"
}
```

`authkey` + `district` required; `advertise_routes` and `hostname` optional.

## Day 2

On any deployed Pi (via `tailscale ssh dcs@<hostname>`):

```bash
sudo dcs status       # enrollment state, routes, peers
sudo dcs stats        # uptime, load, temp, Zabbix proxy
sudo dcs logs         # pick a service, tail the journal
sudo dcs routes       # view/edit advertised subnets
sudo dcs reconfigure  # re-run setup (swap district or authkey)
sudo dcs reset        # logout + wipe local state
```

## Repo layout

| Path | Purpose |
|---|---|
| `image/`                        | pi-gen build driver + custom `stage-dcs`. |
| `rootfs/`                       | Files baked into the image (scripts, systemd units, SSH pubkey). |
| `rootfs/usr/local/sbin/dcs-*`   | Runtime tools (`dcs-enroll`, `dcs-setup`, `dcs`, `dcs-heartbeat`). |
| `install.sh`                    | LAN-style installer for converting a fresh Raspberry Pi OS into a DCS Pi (alternative to flashing the golden image). |
| `docs/OPS_RUNBOOK.md`           | Architecture, onboarding, troubleshooting, verification. |
| `tests/`                        | Integration tests — run with `python3 tests/test_enroll_integration.py`. |

## What NOT to commit

The tree itself contains no secrets — safe to publish. But never commit:
- Raw pre-auth keys (`tskey-auth-...`)
- The private half of the SSH key whose public half lives at `rootfs/home/dcs/.ssh/authorized_keys`
- Customer-specific ACL policies, tailnet exports, or district names/CIDRs from live deployments

The `.gitignore` already blocks `*.key`, `*.pem`, `deploy/*.img*`, and `work/` (pi-gen output). Secrets pasted into commit messages or new files are your responsibility to avoid.
