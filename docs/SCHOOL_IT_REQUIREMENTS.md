# DCS Pi — Network Requirements for School District IT

**Purpose:** This one-pager lists the exact firewall and content-filter
exemptions the DCS Pi needs to operate. Hand it to the district's network
admin before install. Total effort on their end is typically 5–10 minutes.

---

## What this device is

A Raspberry Pi appliance, ~$120, deployed by Subterra Technologies to
support district network monitoring. It sits in your MDF or IDF, draws
power over PoE+ (no separate power supply needed), and connects to one
ethernet port on your district LAN.

**It is not a VPN for users.** It is a single, dedicated infrastructure
device. No student or staff traffic flows through it. It exists solely so
our monitoring system (Zabbix) can poll your switches, APs, and other
infrastructure that already lives on your LAN.

---

## What it needs from your network

The Pi needs **outbound only** — no port forwards, no public IP, no DMZ.
Specifically, it talks to a service called Tailscale, which is how our
monitoring server reaches it without us asking you to open any inbound
holes in your firewall.

### Required egress for the Pi's source IP / MAC

| Protocol | Destination | Purpose |
|---|---|---|
| **UDP/3478** | `*.tailscale.com` and any public IP | STUN — NAT traversal probe |
| **UDP** ephemeral high ports | any public IP | Direct peer-to-peer keepalive (preferred path; ~6ms latency) |
| **TCP/443** | `*.tailscale.com` (DERP relay servers) | Fallback when UDP is blocked or NAT is hostile |
| **TCP/443** | `controlplane.tailscale.com` | Authentication and tailnet membership |
| **TCP/443** | `pkgs.tailscale.com`, `repo.charm.sh` | Package updates (apt sources) |
| **UDP/53** + **TCP/53** | your DNS resolver | Standard name resolution |
| **UDP/123** | NTP servers (chrony defaults) | Time sync |

Reference (vendor docs): https://tailscale.com/kb/1082/firewall-ports

### What must NOT happen to its traffic

- **No SSL/TLS deep inspection** of traffic to `*.tailscale.com`. Tailscale's
  DERP relay servers pin their own TLS certificates and will reject
  connections that go through an interception proxy installing a corporate
  CA cert. SSL inspection on this domain breaks the device.
- **No "VPN", "anonymizer", or "proxy avoidance" category blocks** applied
  to this device. Many content filters (Lightspeed, GoGuardian, Cisco
  Umbrella, Sophos, Fortinet, Palo Alto) classify Tailscale under these
  categories by default. Exempt the Pi's IP/MAC from those categories, or
  whitelist `*.tailscale.com` explicitly.

### What the Pi will NOT do

- Will not initiate any inbound connection to your LAN that you didn't
  ask for. It is purely a relay for our monitoring polls.
- Will not browse the web, fetch arbitrary content, or proxy user traffic.
- Will not open ports on your firewall or request UPnP forwards (it uses
  outbound-initiated NAT traversal).
- Will not store or transmit student PII, instructional content, or
  any other CIPA-relevant data.

---

## Easiest setup path

If your firewall supports it, the simplest exemption is:

1. **Reserve a static IP** for the Pi (DHCP reservation by MAC works fine).
2. **Apply a "trusted infrastructure" / "bypass content filter" rule** to
   that IP. Many districts already have such a rule for printers, IP
   phones, IP cameras, HVAC controllers, badge readers, and other
   non-user devices. The DCS Pi belongs in the same bucket.
3. **Confirm SSL inspection is disabled** for that IP, or for the
   `*.tailscale.com` domain.

That's it. No domain-by-domain whitelisting, no port-by-port allow rules.

---

## How to verify it's working (after install)

After we install the Pi, you can verify connectivity yourself by SSH'ing
to it (we'll provide credentials and instructions) and running:

```
sudo dcs preflight
```

The output looks like this when everything is permitted:

```
▸ 1. Basic IP egress
  ✓ ICMP to 1.1.1.1 (Cloudflare) — reachable
▸ 2. DNS resolution
  ✓ derp.tailscale.com → 159.89.225.99
▸ 3. Tailscale netcheck (real UDP/DERP probes)
  ✓ UDP egress reaches Tailscale STUN
  ✓ Nearest DERP: dfw, 16.1ms
▸ 4. SNI-based DPI detection
  ✓ TCP/443 to DERP reachable, no SNI-based blocking detected
▸ 5. Summary
  ✓ All checks passed — network permits Tailscale operation
```

Any `✗` line tells you exactly what to fix on the firewall side.

---

## Common firewall product specifics

**Lightspeed Filter / Lightspeed Systems:**
Add the Pi's IP to a "Trusted IP Override" group with full bypass.

**GoGuardian Admin / Teacher:**
GoGuardian filters on the client side via browser extensions; the Pi
runs no GoGuardian agent and is unaffected. No action needed unless
your network has a separate firewall in front.

**Cisco Umbrella:**
Add the Pi's external IP to the "Internal Networks" allow list under
Identities, and make sure no policies block the `Anonymizer` or
`VPN/Proxy` categories for that IP.

**Fortinet FortiGate:**
Create an explicit policy from the Pi's IP outbound to `all` with no
SSL inspection profile. Or exempt `*.tailscale.com` from the existing
policy's SSL inspection.

**Palo Alto:**
Create a Security Policy rule from the Pi to any with App-ID set to
allow `tailscale` (yes, Palo Alto has an explicit App-ID for it). No
Decryption profile.

**Sophos UTM / XG / SG:**
Exempt the Pi's IP from "Web Protection" → "Filter" group. Disable
SSL/TLS inspection on `*.tailscale.com`.

**OPNsense / pfSense / pfBlockerNG:**
Remove the Pi's IP from any DNSBL or IP-block lists. Tailscale's
DigitalOcean DERP IPs sometimes show up in cloud-provider blocklists.

---

## Questions

If your network admin has questions or runs into issues, we are happy
to get on a call and walk through the configuration together. Contact:

**Subterra Technologies** — `noah@subterratechnologies.com`

---

*This document lives at*
*`https://github.com/Subterra-Technologies/dcs-pi-image/blob/main/docs/SCHOOL_IT_REQUIREMENTS.md`*
*— always pull the latest version before each deployment.*
