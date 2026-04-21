# Detel Fleet — Ops Runbook

Operational procedures for the Detel fleet. Portable, lives in-repo so it's reachable without Docmost.

Two repos to know:

- `detel-hub` — Headscale back-compat coordinator + admin CLI + Zabbix-VM bootstrap + dashboard + backup/cert-check
- `detel-pi-image` — Pi 5 golden image (this repo)

Control plane is **Tailscale SaaS**. The self-hosted Headscale coordinator in `detel-hub` is back-compat only, reachable via the optional `login_server` field in the Pi enrollment config.

---

## 1. Concepts in three lines

- **District = Tailscale tag.** Each district gets its own tag (e.g. `tag:pi-oakridge`, `tag:zabbix-oakridge`). Tag names in this runbook are placeholders — production has unique per-district names.
- **Nodes are tagged.** A Pi carries the district's `tag:pi-*`; each Zabbix VM carries the district's `tag:zabbix-*`.
- **Isolation is ACL-enforced.** Tailscale ACLs restrict cross-district traffic; ops group has full access.

## 2. Coordinator install (one time, back-compat only)

Only needed if a district Pi will point at self-hosted Headscale via `login_server`. Default path is Tailscale SaaS — skip this section.

Public reachability is via Cloudflare Tunnel — **no edge router port-forwards**. The coordinator has no public inbound ports.

1. Fresh Debian 12+ VM. No public IPv4 required; outbound HTTPS is enough.
2. In the Cloudflare Zero Trust dashboard: Networks → Tunnels → Create tunnel → Cloudflared. Name it (e.g. `detel-hub`). Copy the install token. On the Public Hostnames tab, add: Subdomain = `hub`, Domain = `detel.one`, Type = `HTTP`, URL = `localhost:8080`. DNS is created automatically (CNAME to the tunnel).
3. On the VM:
   ```
   git clone <detel-hub repo> /opt/detel-hub-src
   sudo /opt/detel-hub-src/setup.sh          # writes template env, exits
   sudo vi /etc/detel-hub/setup.env          # set COORDINATOR_HOSTNAME,
                                             #   CLOUDFLARE_TUNNEL_TOKEN,
                                             #   OPS_EMAIL, MGMT_CIDR
   sudo /opt/detel-hub-src/setup.sh          # real install; installs cloudflared too
   ```
4. Verify:
   ```
   sudo systemctl status headscale cloudflared detel-dashboard
   sudo detel-admin list-districts            # empty, but no error
   curl -fsS https://hub.detel.one/health    # should be 200, via Cloudflare
   ```
   If the public hostname 5xx's, `systemctl status cloudflared` + `journalctl -u cloudflared -e`. If cloudflared is up but 502, check the Public Hostname mapping in Cloudflare (URL = `localhost:8080`).

## 3. Onboarding a new district

### 3a. Provision the Pi (office, TUI flow — primary path)

In the Tailscale admin console: create a tag-scoped pre-auth key for the district's `tag:pi-<slug>`. Copy the `tskey-auth-...` string.

Flash the image and boot the Pi on the office LAN:

```
# ops laptop
ssh detel@detel-pi.local          # ops SSH key is baked into the image
sudo detel-setup                  # TUI
```

Answer four prompts:

- District slug (e.g. `oakridge`)
- School LAN CIDR (e.g. `10.42.0.0/24`) — ask district IT; this is what gets advertised
- Hostname (blank = auto `<slug>-pi-<serial8>`)
- Paste the Tailscale authkey

The TUI writes `/boot/firmware/detel-enroll.json` with explicit `advertise_routes`, kicks `first-boot.service`, which joins the tailnet and reboots. Verify in the Tailscale admin panel that the node is online with the expected tag and advertised routes.

```
sudo poweroff                     # ship it
```

At the school, the Pi boots, picks up the school LAN on its primary interface, and re-advertises the pre-declared school CIDR. Routes auto-approve via tailnet ACL `autoApprovers` (RFC1918 for `tag:pi-*`).

### 3b. Fallback: unattended JSON seeding

If you can't SSH to the Pi (e.g. no office LAN at flash time), mount the boot partition on the flash bench and drop in `/boot/firmware/detel-enroll.json` directly:

```json
{
  "authkey": "tskey-auth-...",
  "district": "<slug>",
  "advertise_routes": ["10.42.0.0/24"],
  "hostname": "<slug>-pi-main"
}
```

Fields: `authkey` and `district` required. `advertise_routes` optional (the enroll script merges any auto-detected primary subnet on top). `hostname` optional (default `<district>-pi-<serial8>`). `login_server` optional — set only when dialing self-hosted Headscale; omit for Tailscale SaaS.

### 3c. Stand up Zabbix VMs for the district

For each Zabbix VM:

- Create the VM on Proxmox. No public IP needed; only outbound internet.
- Issue a Tailscale pre-auth key scoped to `tag:zabbix-<slug>`.
- On the Zabbix VM:
  ```
  git clone <detel-hub repo> /tmp/hub
  sudo /tmp/hub/zabbix-vm/bootstrap.sh \
      --authkey tskey-auth-... \
      --hostname zabbix-<slug>-a
  ```
- Verify in the Tailscale admin panel, or from the hub coordinator if running: `sudo detel-admin list-nodes <slug>`.

### 3d. Configure Zabbix hosts

Add district devices to Zabbix using their **real IPs**. The Pi's subnet routes make them reachable. Example: switch at real `10.0.0.1` → enter `10.0.0.1` in Zabbix host interface, associate with that district's Zabbix VM. No virtual addresses, no translation.

## 4. Revoking a Pi or Zabbix VM

```
sudo detel-admin delete-node <hostname>
```

Node is removed from the tailnet; its tunnel drops within seconds. If it's a compromised Pi, also power it off remotely — it still has its Tailscale keys until you wipe the NVMe.

## 5. Updating ACL policy

Primary path (Tailscale SaaS): edit the ACL in the Tailscale admin console → Access Controls. Save — changes apply instantly.

Back-compat (self-hosted Headscale): edit `/etc/headscale/acl.hujson` on the coordinator, then:

```
sudo detel-admin policy-reload    # if supported by your headscale version
# or
sudo systemctl restart headscale     # brief disconnect (~5s) for all nodes
```

Policy mode `file` reloads on SIGHUP in current versions; the restart path is the safe fallback.

## 6. Ops SSH to any node

From your ops laptop (joined to the tailnet as a `group:ops` member):

```
tailscale ssh detel@<pi-hostname>
tailscale ssh detel@zabbix-oakridge-a
```

No SSH keys to distribute. ACL governs who can SSH where. Sessions are logged via Tailscale.

## 7. Checking fleet health

Primary: Tailscale admin console → Machines. Per-tag filter for district view; each machine's page shows approved routes, last-seen, and NAT type.

Back-compat (self-hosted Headscale) — LAN dashboard from any workstation inside `MGMT_CIDR`:

```
http://<coordinator>:8081     # summary + per-district table + outstanding keys
```

CLI on the coordinator:

```
sudo detel-admin list-nodes             # everything in the tailnet
sudo detel-admin routes                 # advertised + approved routes
sudo detel-admin keys list              # outstanding (unclaimed) pre-auth keys
sudo headscale nodes list --output json | jq '.[] | {name, online, lastSeen}'
```

Pi-side:

```
tailscale status
journalctl -u detel-heartbeat --since -10m
```

## 8. Troubleshooting

| Symptom | First check | Likely cause |
|---|---|---|
| Pi never appears in Tailscale admin (or `list-nodes` on back-compat) | `journalctl -u first-boot` on Pi; `tailscale status` | Auth key expired / wrong / wrong tag; school firewall blocking outbound HTTPS |
| `detel-setup` TUI can't reach the Pi | `ping detel-pi.local` / check Avahi; fall back to the Pi's DHCP lease IP | Office LAN blocks mDNS, or image was flashed with no authorized_keys overlay |
| Node shows online but Zabbix can't reach a school device | `detel-admin routes <slug>` (or admin console → routes) — is the real subnet approved? | Route not auto-approved (non-RFC1918) — approve manually in admin console, or `detel-admin approve-route <node-id> <cidr>` |
| `tailscale ssh` denied | ACL doesn't grant your email to `group:ops`, or destination tag missing | Edit Tailscale ACL (admin console), or `/etc/headscale/acl.hujson` on back-compat + reload |
| Tunnel flaps intermittently | `tailscale netcheck` on the node — UDP path vs DERP fallback | Common on restrictive school WiFi; DERP fallback on TCP/443 handles it |
| Headscale won't start after reboot | `journalctl -u headscale -e` | Config syntax error after upgrade, or SQLite corruption — restore from `/var/backups/detel-hub` |
| Public hostname 502s | `systemctl status cloudflared`; `journalctl -u cloudflared -e` | cloudflared down or tunnel token rotated. Re-run `cloudflared service install <TOKEN>` after updating `setup.env`. Note `cert-check` will still pass because Cloudflare's edge cert stays valid |
| `detel-cert-check` WARN or FAIL | `journalctl -u detel-cert-check` | Under Cloudflare Tunnel, Cloudflare owns the cert and it rarely WARN's. If it does, check DNS + Cloudflare hostname config; exit 1 = <14d, exit 2 = endpoint unreachable |

## 9. Building a new image

```
cd detel-pi-image
./image/build.sh          # reuses pi-gen clone
./image/build.sh --clean  # from scratch
```

Output in `./deploy/*.img.xz`. Flash to NVMe via USB M.2 dock.

## 10. End-to-end verification (before first production ship)

1. (Back-compat only) Coordinator up, `curl https://hub.detel.one/health` returns 200 from the public internet.
2. Test Pi flashed, `ssh detel@detel-pi.local` works, `sudo detel-setup` completes, node appears in Tailscale admin in <120 s.
3. From a Zabbix VM in the test district: ping a real device IP at the school. Should resolve through the subnet route.
4. **PoE-cycle 20×.** Filesystem clean, tailnet re-establishes automatically via PersistentKeepalive equivalent.
5. **Flaky-link recovery.** Block outbound UDP/41641 on the test firewall for 5 min; Tailscale falls back to DERP/TCP-443. Unblock; direct path resumes.
6. **Two districts, overlapping real subnets.** Two test districts both using `192.168.1.0/24`. Each Zabbix VM reaches its own district's hosts without cross-contamination (ACL + per-user subnet routing).
7. **ACL revoke test.** Delete a node via `detel-admin delete-node`; its connection drops in seconds.
8. **Ops SSH test.** `tailscale ssh detel@<pi-hostname>` from the ops laptop works; denied for an ops-not-in-group user.

## 11. Running the test suites

```
# Hub smoke (headscale v0.28 in /tmp; exercises detel-admin incl. `keys list`):
cd detel-hub
./tests/test_hub_smoke.sh

# Backup + restore round-trip (seed → backup → wipe → restore → verify):
./tests/test_backup_restore.sh

# Dashboard smoke (boots headscale + dashboard in /tmp; hits /, /api/status, /healthz):
./tests/test_dashboard.sh

# Pi DRY_RUN:
cd ../detel-pi-image
python3 tests/test_enroll_integration.py
```

All four should print `OK:` on success. Run before every release.

## 12. Backups

Back-compat only: relevant when you're running self-hosted Headscale. Automated by `detel-backup.timer` on the coordinator (installed by `setup.sh` from `detel-hub`). Runs `scripts/backup.sh` nightly at 03:00.

What it captures, per snapshot, in `/var/backups/detel-hub/<UTC-timestamp>/`:

- `db.sql.gz` — gzipped `sqlite3 .dump` of `/var/lib/headscale/db.sqlite` (WAL-safe)
- `noise_private.key` — server identity; lose this and every node must re-register
- `config.yaml` + `acl.hujson` — from `/etc/headscale/`
- `manifest.txt` — timestamp, hostname, headscale version, file sizes

Retention: 14 days (`DETEL_BACKUP_RETENTION=14`). Older snapshot directories are removed on each run.

Offsite (optional): set `DETEL_BACKUP_REMOTE=<rsync-target>` (e.g. `user@host:/path/`) in `/etc/detel-hub/backup.env`. After each local snapshot the script runs `rsync -a --delete` to the remote. Failure is WARN-level, not fatal.

### Restore procedure

```
sudo ls -1 /var/backups/detel-hub/                     # pick a snapshot
sudo detel-restore /var/backups/detel-hub/<ts>      # restore-in-place
```

`detel-restore` stops headscale, refuses to clobber an existing `db.sqlite` without `--force`, extracts the dump, reinstalls the noise key + config + ACL, fixes ownership to `headscale:headscale`, starts the service, and runs `headscale users list` as a sanity check. Test-harness mode: `DETEL_SKIP_SYSTEMCTL=1` (used by `tests/test_backup_restore.sh`).

Covered by `detel-hub/tests/test_backup_restore.sh` — round-trip: seed state → backup → wipe → restore → verify users + preauthkeys return.
