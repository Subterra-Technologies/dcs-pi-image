# Subterra Fleet — Ops Runbook

Operational procedures for the Headscale + Tailscale fleet. Portable, lives in-repo so it's reachable without Docmost.

Two repos to know:

- `subterra-wg-hub` — Headscale coordinator + admin CLI + Zabbix-VM bootstrap
- `subterra-pi-image` — Pi 5 golden image (this repo)

---

## 1. Concepts in three lines

- **District = Headscale user.** Every district gets one user. Slug = user name.
- **Nodes are tagged.** `tag:pi` for the Pi at the main school; `tag:zabbix` for each Zabbix VM in that district.
- **Isolation is ACL-enforced.** `autogroup:member` can reach `autogroup:self:*` (same user only). Ops has full access.

## 2. Coordinator install (one time)

1. Fresh Debian 12+ VM. Public IPv4. DNS A record `hub.subterra.one` → that IP.
2. Edge router port-forwards: TCP/80 (ACME HTTP-01) + TCP/443 (Headscale API + DERP fallback) → this VM.
3. On the VM:
   ```
   git clone <subterra-wg-hub repo> /opt/subterra-hub-src
   sudo /opt/subterra-hub-src/setup.sh          # writes template env, exits
   sudo vi /etc/subterra-hub/setup.env          # set COORDINATOR_HOSTNAME, ACME_EMAIL, OPS_EMAIL
   sudo /opt/subterra-hub-src/setup.sh          # real install
   ```
4. Verify:
   ```
   sudo systemctl status headscale
   sudo subterra-admin list-districts            # empty, but no error
   curl -fsS https://hub.subterra.one/health    # should be 200
   ```
   If ACME fails, check ports 80+443 reachable and DNS correct.

## 3. Onboarding a new district

All commands run on the coordinator VM as an admin with sudo access.

1. **Create the district.**
   ```
   sudo subterra-admin add-district <slug>
   ```
   Slug rule: lowercase, hyphen-separated, unique. Example: `oakridge`, `lincoln-city`.

2. **Issue a pre-auth key for the Pi.**
   ```
   sudo subterra-admin issue-token <slug> pi --expiration 14d
   ```
   Raw `hskey-auth-...` string is printed. Capture it — only chance to see it.

3. **Drop the key onto a Pi's NVMe.** On the ops flash bench:
   - Flash `subterra-pi-*-lite.img.xz` to a USB-M.2 dock.
   - Mount the boot partition. Create `subterra-enroll.json`:
     ```json
     {
       "authkey": "hskey-auth-...",
       "coordinator": "https://hub.subterra.one",
       "district": "<slug>",
       "advertise_routes": ["192.168.1.0/24", "192.168.10.0/24", "10.5.0.0/24"]
     }
     ```
     `advertise_routes` is ops-declared district LAN subnets (ask district IT). Auto-detected primary subnet merges in on top.
   - Unmount, seat NVMe in Pi 5 + M.2 HAT+.
   - One-time per Pi, before shipping: boot with keyboard + HDMI, run `sudo rpi-eeprom-config --edit`, set `BOOT_ORDER=0xf416`, reboot.
   - Ship.

4. **Pi boots at school.** Auto-enrolls in <2 minutes. Verify:
   ```
   sudo subterra-admin list-nodes <slug>
   # should show the Pi with its tag:pi and Tailscale IP
   ```
   Approved routes auto-advertise by policy (RFC1918 is auto-approved for `tag:pi`). Verify:
   ```
   sudo subterra-admin routes <slug>
   ```

5. **Stand up Zabbix VMs for that district.** For each Zabbix VM:
   - Create the VM on Proxmox. No public IP needed; only outbound internet.
   - Issue a Zabbix-role token on the coordinator:
     ```
     sudo subterra-admin issue-token <slug> zabbix
     ```
   - On the Zabbix VM:
     ```
     git clone <subterra-wg-hub repo> /tmp/hub
     sudo /tmp/hub/zabbix-vm/bootstrap.sh \
         --coordinator https://hub.subterra.one \
         --authkey hskey-auth-... \
         --hostname zabbix-<slug>-a
     ```
   - Verify on the coordinator:
     ```
     sudo subterra-admin list-nodes <slug>
     # Should now list both the Pi and the Zabbix VM
     ```

6. **Configure Zabbix hosts.** Add district devices to Zabbix using their **real IPs**. The Pi's subnet routes make them reachable. Example: switch at real `10.0.0.1` → enter `10.0.0.1` in Zabbix host interface, associate with that district's Zabbix VM. No virtual addresses, no translation.

## 4. Revoking a Pi or Zabbix VM

```
sudo subterra-admin delete-node <hostname>
```

Node is removed from the tailnet; its tunnel drops within seconds. If it's a compromised Pi, also power it off remotely — it still has its Tailscale keys until you wipe the NVMe.

## 5. Updating ACL policy

Edit `/etc/headscale/acl.hujson` on the coordinator, then:

```
sudo subterra-admin policy-reload    # if supported by your headscale version
# or
sudo systemctl restart headscale     # brief disconnect (~5s) for all nodes
```

Policy mode `file` reloads on SIGHUP in current versions; the restart path is the safe fallback.

## 6. Ops SSH to any node

From your ops laptop (joined to the tailnet as a `group:ops` member):

```
tailscale ssh subterra@<pi-hostname>
tailscale ssh subterra@zabbix-oakridge-a
```

No SSH keys to distribute. ACL governs who can SSH where. Sessions are logged via Tailscale.

## 7. Checking fleet health

```
sudo subterra-admin list-nodes             # everything in the tailnet
sudo subterra-admin routes                 # advertised + approved routes
sudo headscale nodes list --output json | jq '.[] | {name, online, lastSeen}'
```

Pi-side:

```
tailscale status
journalctl -u subterra-heartbeat --since -10m
```

## 8. Troubleshooting

| Symptom | First check | Likely cause |
|---|---|---|
| Pi never appears in `list-nodes` | `journalctl -u first-boot` on Pi; `tailscale status` | Auth key expired / wrong; school firewall blocking outbound HTTPS |
| Node shows online but Zabbix can't reach a school device | `subterra-admin routes <slug>` — is the real subnet approved? | Route not auto-approved (non-RFC1918) — approve manually: `subterra-admin approve-route <node-id> <cidr>` |
| `tailscale ssh` denied | ACL doesn't grant your email to `group:ops`, or destination tag missing | Edit `/etc/headscale/acl.hujson` + reload |
| Tunnel flaps intermittently | `tailscale netcheck` on the node — UDP path vs DERP fallback | Common on restrictive school WiFi; DERP fallback on TCP/443 handles it |
| Headscale won't start after reboot | `journalctl -u headscale -e` | Most commonly ACME cert expired; check ports 80/443 still forwarded + DNS correct |

## 9. Building a new image

```
cd subterra-pi-image
./image/build.sh          # reuses pi-gen clone
./image/build.sh --clean  # from scratch
```

Output in `./deploy/*.img.xz`. Flash to NVMe via USB M.2 dock.

## 10. End-to-end verification (before first production ship)

1. Coordinator up, `curl https://hub.subterra.one/health` returns 200 from the public internet.
2. Test Pi flashed, bench PoE+ + test school LAN, cold boot to `list-nodes` presence in <120 s.
3. From a Zabbix VM in the test district: ping a real device IP at the school. Should resolve through the subnet route.
4. **PoE-cycle 20×.** Filesystem clean, tailnet re-establishes automatically via PersistentKeepalive equivalent.
5. **Flaky-link recovery.** Block outbound UDP/41641 on the test firewall for 5 min; Tailscale falls back to DERP/TCP-443. Unblock; direct path resumes.
6. **Two districts, overlapping real subnets.** Two test districts both using `192.168.1.0/24`. Each Zabbix VM reaches its own district's hosts without cross-contamination (ACL + per-user subnet routing).
7. **ACL revoke test.** Delete a node via `subterra-admin delete-node`; its connection drops in seconds.
8. **Ops SSH test.** `tailscale ssh subterra@<pi-hostname>` from the ops laptop works; denied for an ops-not-in-group user.

## 11. Running the test suites

```
# Hub smoke (downloads headscale v0.28 binary, runs in /tmp):
cd subterra-wg-hub
./tests/test_hub_smoke.sh

# Pi DRY_RUN:
cd subterra-pi-image
python3 tests/test_enroll_integration.py
```

Both should print `OK:` on success. Run before every release.

## 12. Backups

Back up these on the coordinator:

- `/var/lib/headscale/db.sqlite` — tailnet state
- `/var/lib/headscale/noise_private.key` — server identity
- `/etc/headscale/acl.hujson` — policy
- `/etc/headscale/config.yaml` — server config

Nightly `sqlite3 db.sqlite .dump > /backup/$(date +%F).sql` off-host is enough. Losing the DB means every node has to re-register; losing the noise key means nodes can't verify the server.
