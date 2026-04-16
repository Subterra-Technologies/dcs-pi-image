# Subterra WG Fleet — Ops Runbook

Operational procedures for the WireGuard fleet: bringing up the concentrator, onboarding a school, approving and revoking Pis, and recovering from common failures.

Two repos are referenced throughout:

- `subterra-wg-hub` — datacenter concentrator + enrollment service
- `subterra-pi-image` — Pi 5 golden image (this repo)

---

## 1. Concentrator initial deploy (one-time per hub)

Target: a fresh Debian 12+ VM with a public IPv4 address.

1. Provision the VM: 2 vCPU, 2 GB RAM, 20 GB disk. Open UDP/51820 and TCP/8443 on the provider firewall. TCP/22 only from the ops management CIDR.
2. `git clone <hub-repo> /opt/subterra-hub-src` on the VM.
3. `sudo /opt/subterra-hub-src/setup.sh` — writes `/etc/subterra-hub/setup.env` and exits. Edit that file to fill in `MONITORING_CIDR` (e.g. `10.10.99.0/28` — the block your Zabbix VMs live in), `MGMT_CIDR`, `WG_ENDPOINT`, then re-run `sudo /opt/subterra-hub-src/setup.sh`.
4. At the end, setup prints the hub's WG public key. Record it — it's also at `/etc/wireguard/hub.pubkey`.
5. Point DNS for `WG_ENDPOINT` at the VM's public IP. Verify reachability:
   ```
   sudo systemctl status enrollment.service
   curl -sSf https://hub.example.com:8443/healthz
   ```
6. Add a route on the DC core for `10.200.0.0/16` and for each allocated per-school virtual `/16` (`10.100.0.0/16` through `10.199.0.0/16`) pointing at the concentrator. Zabbix server must be able to reach those via the concentrator.
7. Lock down: the concentrator's FORWARD chain only allows `MONITORING_CIDR`. Every Zabbix VM that needs school access must live inside that CIDR. Scaling out: add a new Zabbix VM on an IP inside `MONITORING_CIDR` — no concentrator edits required.

## 2. Per-school onboarding

### 2a. Record the school in the hub

```bash
sudo -u subterra-hub /opt/subterra-hub/.venv/bin/subterra-hub \
    add-school oakridge "Oakridge ISD"
```

Slugs must be lowercase, hyphen-separated, unique. Keep them stable — they become the Pi hostname prefix (`oakridge-pi01`, `oakridge-pi02`, …).

### 2b. Generate a one-time enrollment token

```bash
sudo -u subterra-hub /opt/subterra-hub/.venv/bin/subterra-hub \
    issue-token oakridge --valid-days 14
```

The command prints the raw token on stdout. This is the **only** time it's shown — capture it immediately. The token is stored hashed; you cannot retrieve it later.

### 2c. Flash a Pi

One-time per Pi, done on the ops bench:

1. On a USB M.2 NVMe dock, flash the latest `subterra-pi-*-lite.img.xz` (produced by `image/build.sh`, see §7) to the NVMe drive.
2. Mount the boot partition (`/boot/firmware` on the target — usually the first FAT partition on the NVMe).
3. Create `subterra-enroll.json` on that partition:
   ```json
   {
     "enroll_token": "<paste-the-raw-token>",
     "enrollment_url": "https://hub.example.com:8443",
     "candidate_subnets": ["192.168.1.0/24", "192.168.10.0/24"]
   }
   ```
   `candidate_subnets` is optional but strongly recommended — it's the list of real school subnets the Pi should NETMAP. The Pi will auto-detect its primary subnet on top of these. Only `/24` subnets are supported today.
4. Unmount and seat the NVMe in the Pi's M.2 HAT+.
5. One-time EEPROM boot order (do this once per Pi before shipping):
   ```
   sudo rpi-eeprom-config --edit
   # Ensure: BOOT_ORDER=0xf416  (NVMe, USB, network, restart)
   sudo reboot
   ```
   Subsequent NVMe swaps do not need this again.
6. Label the Pi case with the school slug and the token's last 6 chars (for reconciliation at approval time).
7. Ship.

### 2d. First boot at the school

School IT plugs the Pi into a PoE+ port and a LAN port. Expected sequence:

1. Pi boots from NVMe (~30 s).
2. `first-boot.service` runs `subterra-enroll`: generates WG keypair, detects LAN, POSTs to the hub with exponential backoff.
3. On success, Pi writes `wg0.conf`, installs NETMAP rules, enables `wg-quick@wg0` and `subterra-heartbeat.timer`, then reboots once.
4. After reboot, tunnel comes up but will **not** establish handshakes until ops approves — the hub has the peer in `pending` state.

Total elapsed: under 2 minutes from cold boot to `pending` appearing on the hub.

### 2e. Approve

On the hub:

```bash
sudo -u subterra-hub /opt/subterra-hub/.venv/bin/subterra-hub list-pending
# Verify serial matches the label on the shipped Pi.
sudo -u subterra-hub /opt/subterra-hub/.venv/bin/subterra-hub approve <SERIAL>
```

The hub regenerates `wg0.conf`, calls `wg syncconf wg0`, and the tunnel becomes active within seconds. The Pi's `PersistentKeepalive=25` brings the handshake up without a restart.

Confirm:

```bash
sudo -u subterra-hub /opt/subterra-hub/.venv/bin/subterra-hub handshakes
# Expect the new peer to show a recent handshake.
```

## 3. Zabbix configuration

After approval, the school is reachable at its virtual `/16`. If a real subnet is `192.168.5.0/24`, the Pi NETMAPs it to `<virtual_slice>.5.0/24` where `virtual_slice` is the first two octets of the school's virtual `/16`.

Example: school `oakridge` assigned virtual `10.100.0.0/16` + real `192.168.5.0/24` → device at real `192.168.5.42` is reachable from Zabbix at `10.100.5.42`.

Add the Zabbix host with the virtual IP as its interface address. SNMP/ICMP/agent polling all work through the tunnel transparently.

### 3a. Migrating a school to `zabbix-proxy`

`zabbix-proxy-sqlite3` is pre-installed on every Pi but disabled. To flip:

```bash
# SSH into the Pi via its tunnel IP (from the concentrator's 10.200.0.0/16 overlay).
ssh subterra@10.200.0.2
sudo systemctl enable --now zabbix-proxy
# Edit /etc/zabbix/zabbix_proxy.conf for Server=<zabbix-server> and ProxyMode.
```

Then on the Zabbix server, reassign that school's hosts from direct polling to the new proxy.

## 4. Revoking a school

```bash
sudo -u subterra-hub /opt/subterra-hub/.venv/bin/subterra-hub revoke <SERIAL>
```

Sets the peer to `revoked`, regenerates `wg0.conf`, calls `wg syncconf`. The tunnel drops within seconds. The Pi will continue to retry handshakes (no-op from the hub's perspective). If you want it off the network permanently, also power it down — the Pi still has its keys locally.

## 5. Maintenance

### Rotating the hub key

This invalidates every Pi's config. Only do this in response to a compromise.

1. `sudo systemctl stop enrollment.service wg-quick@wg0.service`
2. `sudo rm /etc/wireguard/hub.key /etc/wireguard/hub.pubkey /etc/wireguard/wg0.conf`
3. Re-run `sudo /opt/subterra-hub-src/setup.sh` (regenerates keys).
4. For each active school, reissue tokens and redeploy Pis (they must re-enroll).

### Updating the image

1. Cut a release of `subterra-pi-image`; run `./image/build.sh`.
2. Flash new NVMes for new shipments from the new image.
3. For deployed Pis, in-place updates ride on `unattended-upgrades` (security only). For larger changes, ship a new NVMe as a swap.

### Checking tunnel health

```bash
# On the hub:
sudo -u subterra-hub /opt/subterra-hub/.venv/bin/subterra-hub handshakes
sudo wg show wg0

# On a specific Pi (via tunnel):
sudo journalctl -u subterra-heartbeat --since '-10m'
sudo wg show wg0
```

## 6. Troubleshooting

| Symptom | Likely cause | What to check |
|---|---|---|
| Pi never appears as pending on the hub | DNS/firewall blocks outbound UDP or the enrollment URL is unreachable | On the Pi: `journalctl -u first-boot` shows retry loop. From school LAN: `curl -v https://hub.example.com:8443/healthz` |
| Pi enrolls but tunnel won't come up | Peer is still `pending` | Check `subterra-hub list-pending`, approve |
| Tunnel up but Zabbix can't reach virtual IP | Missing DC route for that school's virtual `/16`, or FORWARD rule blocks | `ip route` on concentrator + Zabbix; `iptables -L FORWARD -v` on concentrator |
| Zabbix can ping virtual network gateway but not hosts | NETMAP rule missing for that real subnet | On Pi: `sudo iptables -t nat -L PREROUTING -v` |
| Pi reboots every 10 min | Hardware watchdog tripped — kernel hang | `journalctl -b -1` on Pi |
| `wg-quick@wg0` fails on boot | `wg0.conf` corrupted or missing after power-cut | `cat /etc/wireguard/wg0.conf`; if bad, re-flash (enrollment sentinel gates re-enroll; `rm /var/lib/subterra/enrolled` to force) |

## 7. Building the image

```bash
cd subterra-pi-image
./image/build.sh         # reuses pi-gen clone
./image/build.sh --clean # from-scratch build
```

Requires Docker on the build host. Output lands in `./deploy/` as `*.img.xz`. Flash with `rpi-imager` or `dd` to the NVMe on a M.2 USB dock.

## 8. End-to-end verification (pre-production)

Run before shipping the first real school Pi. Nine steps:

1. **Concentrator up.** Fresh VM, `setup.sh`, confirm `systemctl status enrollment.service wg-quick@wg0.service` both green. `curl -fsS https://hub:8443/healthz` returns `{"status":"ok"}` from the public internet.
2. **Image builds clean.** `./image/build.sh --clean` produces a `.img.xz` without errors.
3. **Cold-boot-to-pending in <120 s.** Flash one test Pi. Plug into bench PoE + test LAN. Time from PoE-on to the enrollment appearing in `list-pending`. Must be <120 s.
4. **Approved tunnel carries traffic.** Approve. From the Zabbix server: `ping`, `snmpwalk`, and `curl` against a test device via its virtual IP. Use `tcpdump` on the Pi's `eth0` to confirm rewritten (real) IPs. Use `tcpdump` on `wg0` to confirm virtual IPs.
5. **PoE-cycle 20×.** Via the switch: `no power inline` / `power inline` on the port, 10–60 s between cycles. After each cycle: `dmesg | grep -iE 'ext4|ata|error'` should be clean; tunnel re-establishes within 60 s; heartbeat resumes in journal.
6. **Flaky-link recovery.** Block UDP/51820 on the bench firewall for 5 min, unblock. Tunnel self-recovers via `PersistentKeepalive` — no intervention.
7. **Overlap test.** Stand up a second test Pi on an identical real LAN (`192.168.1.0/24`). Confirm Zabbix can address both schools' devices via their distinct virtual `/16`s with no collision.
8. **Proxy flip.** On one test Pi: `systemctl enable --now zabbix-proxy`. Confirm it registers with the Zabbix server over the tunnel and pushes data. Then `systemctl disable --now zabbix-proxy`; confirm direct polling still works.
9. **Revocation.** `subterra-hub revoke <serial>` on the hub. Confirm `wg syncconf` removed the peer within 5 s (`wg show wg0` no longer lists it); Pi still retries but never handshakes.

## 9. Running the test suites

Both repos ship integration tests that exercise the code without touching the system network stack.

```bash
# Hub unit + enrollment e2e:
cd subterra-wg-hub
.venv/bin/python tests/test_enroll_flow.py

# Pi-side script against a running hub (both repos on the same host):
cd subterra-pi-image
python3 tests/test_enroll_integration.py
```

Both must print `OK:` on success. Run before every release.
