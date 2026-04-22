# DCS Fleet — Ops Runbook

Operational procedures for the DCS fleet. Portable, lives in-repo so it's reachable without Docmost.

Two repos to know:

- `dcs-hub` — Zabbix-VM bootstrap (datacenter side)
- `dcs-pi-image` — Pi 5 golden image (this repo)

Control plane is **Tailscale SaaS**. No self-hosted coordinator.

---

## 1. Concepts in three lines

- **District = Tailscale tag.** Each district gets its own tag (e.g. `tag:pi-oakridge`, `tag:zabbix-oakridge`). Tag names in this runbook are placeholders — production has unique per-district names.
- **Nodes are tagged.** A Pi carries the district's `tag:pi-*`; each Zabbix VM carries the district's `tag:zabbix-*`.
- **Isolation is ACL-enforced.** Tailscale ACLs restrict cross-district traffic; ops group has full access.

## 2. Onboarding a new district

### 2a. Provision the Pi — ◆ SCHOOL SIDE ◆ (office, clone-and-run flow — primary path)

No golden image required. Flash plain Raspberry Pi OS Lite, SSH in, clone the repo, run the installer.

In the Tailscale admin console: create a tag-scoped pre-auth key for the district's `tag:pi-<slug>`. Copy the `tskey-auth-...` string.

**Flash and first boot (office):**

1. **Flash** Raspberry Pi OS Lite (64-bit) to NVMe/SD with **rpi-imager**. Advanced options: set hostname, username + password, enable SSH.
2. **Boot** the Pi on the office LAN with PoE+. SSH in with your user/password:
   ```
   ssh <user>@<pi>.local
   ```
3. **Clone and install:**
   ```
   git clone https://github.com/Subterra-Technologies/dcs-pi-image /tmp/dcs
   sudo bash /tmp/dcs/install.sh
   ```
   The installer adds Tailscale + Charm apt repos, installs `tailscale`, `gum`, and `jq`, creates the `dcs` user, drops the DCS binaries + systemd units, disables root login, and launches `dcs-setup`. (Pre-bake OAuth creds by exporting `DCS_TS_OAUTH_CLIENT_ID` / `DCS_TS_OAUTH_CLIENT_SECRET` and running with `sudo -E` to skip the TUI's OAuth prompt — optional.)
4. **Answer the TUI prompts:**
   - **OAuth client** (first Pi on this image only) — client ID + secret from the Trust credentials page (https://login.tailscale.com/admin/settings/trust-credentials → OAuth clients → Generate) with scopes `devices:core` (Read) + `auth_keys` (Write, with every `tag:pi-*` you'll provision selected on the client). Validated against the token endpoint before persisting to `/etc/dcs.conf`.
   - **District slug** (e.g. `oakridge`).
   - **School LAN CIDRs** — if another Pi is already enrolled in this district, its routes auto-populate as defaults (just press ✓); otherwise type the CIDR, e.g. `10.42.0.0/24`.
   - **Hostname** — auto-suggests the next free letter (`<slug>-pi-a`, `-b`, …) based on existing `tag:pi-<slug>` hostnames. Blank accepts.
   - **Auth key** — minted automatically via `dcs-mint-key` (one-hour, tag-scoped to `tag:pi-<slug>`). Falls back to manual paste if minting fails (e.g. the tag isn't declared in ACL `tagOwners` yet).
5. The TUI writes `/boot/firmware/dcs-enroll.json`, kicks `first-boot.service`, verifies the tag, and reboots.

   **ACL prerequisite.** Before enrolling the first Pi of a new district, declare `tag:pi-<slug>` in `tagOwners` and list its CIDR range under `autoApprovers` in the tailnet policy — **and** add that tag to the OAuth client's `auth_keys` scope in Trust credentials. Otherwise auto-mint returns "API rejected request".

```
sudo poweroff                     # ship it
```

At the school, the Pi boots, picks up the school LAN on its primary interface, and re-advertises the pre-declared school CIDR. Routes auto-approve via tailnet ACL `autoApprovers` (RFC1918 for `tag:pi-*`).

**SSH note.** The installer disables root login but **leaves password authentication enabled** so the user/password you set via rpi-imager keeps working as a break-glass fallback. Day-to-day access should go through Tailscale SSH (`tailscale ssh dcs@<hostname>`), which bypasses sshd entirely.

**Golden-image alternative.** If you want a fully pre-baked `.img.xz` for high-volume deploys, the `image/` directory still has the pi-gen driver (`./image/build.sh`). Most fleets don't need it — the clone-and-run flow above is easier to iterate on.

### 2b. Fallback: unattended JSON seeding

If you can't SSH to the Pi (e.g. no office LAN at flash time), mount the boot partition on the flash bench and drop in `/boot/firmware/dcs-enroll.json` directly:

```json
{
  "authkey": "tskey-auth-...",
  "district": "<slug>",
  "advertise_routes": ["10.42.0.0/24"],
  "hostname": "<slug>-pi-main"
}
```

Fields: `authkey` and `district` required. `advertise_routes` optional (the enroll script merges any auto-detected primary subnet on top). `hostname` optional (default `<district>-pi-<serial8>`).

### 2c. Stand up Zabbix VMs for the district — ◆ MONITORING SIDE ◆ (TUI flow)

**One-time per tailnet (enables the easy path):** Admin console → **Trust credentials** (https://login.tailscale.com/admin/settings/trust-credentials) → OAuth clients → **Generate**. Grant it two scopes:
- `devices:core` with **Read** — lets the TUI show a live picker of existing Pi districts.
- `auth_keys` with **Write** (select every `tag:pi-*` and `tag:zabbix-*` you'll provision) — lets the TUI **auto-mint** the pre-auth key for each VM. The operator never touches the admin console per VM.

Save the client ID + secret (the secret starts with `tskey-client-`) in the team password manager. Without these scopes the TUI still works — it just asks the operator to paste a hand-minted key and/or type the slug.

For each Zabbix VM:

- Create the VM on Proxmox. No public IP needed; only outbound internet.
- On the Zabbix VM:
  ```
  git clone https://github.com/Subterra-Technologies/dcs-hub /tmp/hub
  export DCS_TS_OAUTH_CLIENT_ID=<client-id>
  export DCS_TS_OAUTH_CLIENT_SECRET=<client-secret>
  sudo -E bash /tmp/hub/zabbix-vm/install.sh
  ```
  The installer ensures `tailscale`, `gum`, and `jq` are present, drops `dcs-setup`, `dcs`, `dcs-districts`, and `dcs-mint-key` into `/usr/local/sbin`, persists the OAuth creds to `/etc/dcs.conf` (chmod 0600), then launches the TUI. Answer two prompts:
  - **District** — picker of live Pi-tagged districts (if `devices:core` Read is granted) or free-text slug.
  - **Hostname** — blank = auto `zabbix-<slug>-a`; use `-b`, `-c` for additional VMs.
  The TUI then auto-mints a one-hour pre-auth key via `dcs-mint-key` (if `auth_keys` Write is granted for this tag), runs `tailscale up --authkey … --ssh --accept-routes --accept-dns=false`, validates the assigned tag, and persists `/var/lib/dcs/enrollment.json`. If auto-mint isn't available it falls back to prompting for a pasted key.
- Verify in the Tailscale admin panel that the Zabbix node is online with its district tag and that the district's Pi routes show as reachable.

**Headless alternative (CI / scripted deploys):** skip the TUI and call `bootstrap.sh` with flags:
```
sudo /tmp/hub/zabbix-vm/bootstrap.sh \
    --authkey tskey-auth-... \
    --hostname zabbix-<slug>-a
```
Same effect, no prompts.

After enrollment, the admin TUI is available as `sudo dcs` (menu: status / districts / logs / reconfigure / reset). `sudo dcs districts` prints the Pi fleet from the API for quick sanity-checks.

### 2d. Configure Zabbix hosts

Add district devices to Zabbix using their **real IPs**. The Pi's subnet routes make them reachable. Example: switch at real `10.0.0.1` → enter `10.0.0.1` in Zabbix host interface, associate with that district's Zabbix VM. No virtual addresses, no translation.

## 3. Revoking a Pi or Zabbix VM

Tailscale admin console → Machines → locate the node → Remove. Tunnel drops within seconds. If it's a compromised Pi, also power it off remotely — it still has its Tailscale keys until you wipe the NVMe.

## 4. Updating ACL policy

Edit the ACL in the Tailscale admin console → Access Controls. Save — changes apply instantly.

## 5. Ops SSH to any node

From your ops laptop (joined to the tailnet as a `group:ops` member):

```
tailscale ssh dcs@<pi-hostname>
tailscale ssh dcs@zabbix-oakridge-a
```

No SSH keys to distribute. ACL governs who can SSH where. Sessions are logged via Tailscale.

## 6. Checking fleet health

Tailscale admin console → Machines. Per-tag filter for district view; each machine's page shows approved routes, last-seen, and NAT type.

Pi-side:

```
tailscale status
journalctl -u dcs-heartbeat --since -10m
```

## 7. Troubleshooting

| Symptom | First check | Likely cause |
|---|---|---|
| Pi never appears in Tailscale admin | `journalctl -u first-boot` on Pi; `tailscale status` | Auth key expired / wrong / wrong tag; school firewall blocking outbound HTTPS |
| `dcs-setup` TUI can't reach the Pi | `ping dcs-pi.local` / check Avahi; fall back to the Pi's DHCP lease IP | Office LAN blocks mDNS, or image was flashed with no authorized_keys overlay |
| Node online but Zabbix can't reach a school device | Admin console → node → Subnets: is the real subnet approved? | Route not auto-approved (non-RFC1918) — approve manually in admin console |
| `tailscale ssh` denied | ACL doesn't grant your email to `group:ops`, or destination tag missing | Edit Tailscale ACL in admin console |
| Tunnel flaps intermittently | `tailscale netcheck` on the node — UDP path vs DERP fallback | Common on restrictive school WiFi; DERP fallback on TCP/443 handles it |

## 8. Building a new image

```
cd dcs-pi-image
./image/build.sh          # reuses pi-gen clone
./image/build.sh --clean  # from scratch
```

Output in `./deploy/*.img.xz`. Flash to NVMe via USB M.2 dock.

## 9. End-to-end verification (before first production ship)

1. Test Pi flashed, `ssh dcs@dcs-pi.local` works, `sudo dcs-setup` completes, node appears in Tailscale admin in <120 s.
2. From a Zabbix VM in the test district: ping a real device IP at the school. Should resolve through the subnet route.
3. **PoE-cycle 20×.** Filesystem clean, tailnet re-establishes automatically.
4. **Flaky-link recovery.** Block outbound UDP/41641 on the test firewall for 5 min; Tailscale falls back to DERP/TCP-443. Unblock; direct path resumes.
5. **Two districts, overlapping real subnets.** Two test districts both using `192.168.1.0/24`. Each Zabbix VM reaches its own district's hosts without cross-contamination (ACL + per-tag subnet routing).
6. **ACL revoke test.** Remove a node via the admin console; its connection drops in seconds.
7. **Ops SSH test.** `tailscale ssh dcs@<pi-hostname>` from the ops laptop works; denied for an ops-not-in-group user.

## 10. Running the test suite

```
cd dcs-pi-image
python3 tests/test_enroll_integration.py
```

Should print `OK:` on success. Run before every release.
