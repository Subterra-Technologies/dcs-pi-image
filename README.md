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
   - **OAuth client** (first Pi on this image only) — client ID + client secret from https://login.tailscale.com/admin/settings/trust-credentials → **OAuth clients** → Generate. Scopes: `devices:core` with **Read**, and `auth_keys` with **Write** (select every `tag:pi-*` you'll provision — see gotcha below). The TUI validates the creds live against Tailscale's token endpoint and refuses to continue on failure, then stores them at `/etc/dcs.conf` (mode `0600`). Subsequent Pis on the same image skip this prompt entirely.
   - **District slug** — e.g. `oakridge`
   - **School LAN CIDRs** — if another Pi is already enrolled in this district, its advertised routes auto-populate and you can accept them with a keystroke. Otherwise type the CIDR, e.g. `10.42.0.0/24`.
   - **ACL precheck** — before minting, the TUI reads the tailnet ACL and verifies `tag:pi-<slug>` is in `tagOwners` and every entered CIDR is in `autoApprovers`. On mismatch it prints a copy-pasteable HuJSON snippet and exits. The check is read-only by design — round-tripping the ACL through `jq` would strip comments, so you fix it by hand in the admin console.
   - **Hostname** — auto-suggests the next free letter (`<slug>-pi-a`, `-b`, `-c`, …); blank accepts the suggestion.
   - **Auth key** — minted automatically via `dcs-mint-key` using your OAuth creds. No paste needed unless the mint fails, in which case the TUI surfaces Tailscale's actual error message and offers a paste fallback.
5. The TUI writes the enrollment JSON, kicks `first-boot.service`, verifies the tag, and reboots.
6. **Power off**, ship it. At the school the Pi boots, picks up the LAN, and re-advertises the CIDR. Routes auto-approve via ACL.

### OAuth client gotcha

Even with the `all` scope, the `auth_keys` permission on a Tailscale OAuth client requires **per-tag selection at client-creation time**. If `tag:pi-<slug>` isn't in the client's selected tag list, every mint fails with:

```
requested tags are not owned by this OAuth client
```

Fix: edit the OAuth client at https://login.tailscale.com/admin/settings/trust-credentials and add the tag to the `auth_keys` scope row. The `devices:core` (Read) scope does not have this restriction — it applies tailnet-wide. The ACL precheck uses `policy_file:read` (included in `all`); if you scoped the client more tightly, the precheck will skip with a warning.

**Prerequisite in Tailscale ACL:** `tag:pi-<slug>` must be declared in `tagOwners`, and the district's CIDR(s) must be in `autoApprovers` for `tag:pi-<slug>`, before the first Pi in a district enrolls. The ACL precheck will tell you exactly what's missing.

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
sudo dcs status       # enrollment state, routes, peers, installed version
sudo dcs stats        # uptime, load, temp, Zabbix proxy
sudo dcs logs         # pick a service, tail the journal
sudo dcs routes       # view/edit advertised subnets
sudo dcs update       # pull latest dcs scripts + units from the repo
sudo dcs reconfigure  # re-run setup (swap district or authkey)
sudo dcs reset        # logout + wipe local state
```

`dcs status` includes a **Version** line showing the short SHA of the currently installed `dcs-*` scripts + units (read from `/var/lib/dcs/installed-sha`).

### Updating a deployed Pi

`sudo dcs update` shallow-clones the repo into a tempdir, diffs against the installed SHA, shows the pending commit log, prompts to confirm, then reinstalls every script under `rootfs/usr/local/sbin/` and every unit under `rootfs/etc/systemd/system/`. It does **not** touch `/etc/dcs.conf`, the enrollment JSON, or the tailnet session — it's purely a code refresh. `systemctl daemon-reload` runs automatically and `dcs-heartbeat.timer` is restarted if active.

- Pin a branch/tag/SHA with `DCS_REPO_REF=<ref> sudo -E dcs update` (default: `main`)
- Override the source repo with `DCS_REPO_URL=...` (default: the upstream Subterra-Technologies repo)
- `git` is installed automatically if missing — safe to run on a fresh Pi OS Lite that never had it
- The new SHA is written to `/var/lib/dcs/installed-sha` so `dcs status` reflects it

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

## Troubleshooting

**Auto-mint fails with "requested tags are not owned by this OAuth client"** — the OAuth client needs `tag:pi-<slug>` selected on the `auth_keys` scope row. See the [OAuth client gotcha](#oauth-client-gotcha) above. Even `all` scope does not cover this.

**Auto-mint fails with a different `.message`** — `dcs-mint-key` prints Tailscale's actual error body on any HTTP 4xx/5xx (instead of just the status code). Read the message; it usually points at a missing ACL `tagOwners` entry, an expired client secret, or a tailnet mismatch.

**ACL precheck prints a HuJSON snippet and exits** — copy the snippet into the ACL at https://login.tailscale.com/admin/acls/file, save, re-run `sudo dcs-setup`. The precheck is read-only — it will not write the ACL for you (jq would destroy comments).

**ACL precheck says "OAuth client likely lacks policy_file scope"** — the check is skipped and setup continues. If auto-mint then fails, verify `tagOwners` + `autoApprovers` manually in the admin console.

**`dcs status` shows `Version` as blank** — `/var/lib/dcs/installed-sha` hasn't been written yet (pre-`update`-era install). Run `sudo dcs update` once; it will backfill the file after the first successful update.

## What NOT to commit

The tree itself contains no secrets — safe to publish. Never commit:
- Raw pre-auth keys (`tskey-auth-...`)
- Customer-specific ACL policies, tailnet exports, or district names/CIDRs from live deployments
- `/etc/dcs.conf` (if you use the OAuth-creds install path)

The `.gitignore` already blocks `*.key`, `*.pem`, `deploy/*.img*`, and `work/` (pi-gen output).
