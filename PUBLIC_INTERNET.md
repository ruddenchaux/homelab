# Public Internet Access

Reference document explaining how and why homelab services are exposed to the internet,
including detailed explanations of the underlying protocols and everything that was
implemented and why.

---

## The Problem: Starlink CGNAT

Starlink Residential Lite provides no public IPv4 address. The connection sits behind
**CGNAT** (Carrier-Grade NAT): many customers share the same public IPv4, so inbound
connections to your home are impossible on IPv4.

IPv6 is the partial way out. Starlink provides full public IPv6 connectivity, but
~13% of Italian users have working IPv6, so you still need a solution for IPv4 visitors.

---

## Options Evaluated

| Option | Cost | Pros | Cons |
|--------|------|------|------|
| **VPS + WireGuard** | ~4 €/month | Full IPv4+IPv6, any protocol, full control, streaming OK | Costs money, extra latency hop |
| **IPv6 + Cloudflare proxy** | Free | Zero cost, educational, 100% visitor coverage | Dynamic prefix, Jellyfin TOS violation via proxy |
| **Cloudflare Tunnel** | Free | No inbound ports, works through CGNAT | 100 MB upload limit, TOS prohibits streaming |
| Tailscale Funnel | Free | Simple | No custom domains (only *.ts.net), breaks Authentik cookie |
| ngrok | $8+/month | Simple | Too expensive |

**What was implemented**:
- **IPv6 stack** (Option B): Prepared and ready — MikroTik DHCPv6-PD, k8s dual-stack
  Traefik, external-dns for AAAA records. Needs Phase 2 (real prefix known after testing).
- **VPS + WireGuard** (Option A): **Deployed** for Jellyfin — Hetzner VPS as TCP stream
  relay, WireGuard tunnel to MikroTik, nginx passthrough. `jellyfin.ruddenchaux.xyz` live.
- **Client VPN**: **Deployed** — Android/device VPN via the same VPS, split-tunnel to
  all homelab CIDRs.

---

## Implemented: VPS + WireGuard Relay

### Architecture

```
Internet user (IPv4)
       │
       ▼ TCP 443 (HTTPS)
VPS — 89.167.62.126 (Hetzner CX22, Nuremberg)
       │ nginx stream proxy (blind TCP passthrough)
       │
       ▼ WireGuard tunnel (UDP 51820)
MikroTik — 10.100.0.2 (wg-vps interface)
       │ routes 10.30.0.0/24 via k8s VLAN
       │
       ▼ TCP 443
Traefik — 10.30.0.200 (Cilium L2 LoadBalancer)
       │ hostname routing via SNI/Host header
       │
       ▼
Jellyfin pod (jellyfin.ruddenchaux.xyz)
```

### Why nginx TCP stream (not HTTP proxy)

nginx in `stream {}` mode does a **blind TCP passthrough** — it forwards raw bytes
without reading or modifying the content. TLS is still terminated by Traefik (with
cert-manager certificates). This means:

- The full TLS chain (`jellyfin.ruddenchaux.xyz` cert from Let's Encrypt) works end-to-end
- Authentik ForwardAuth still works (Traefik sees the Host/SNI header unchanged)
- Streaming performance: no HTTP parsing overhead
- Any service Traefik knows about is reachable just by pointing its DNS A record to the VPS

The nginx config is a generic passthrough — it does **not** filter by hostname. Any
service that has its A/AAAA record pointing to the VPS IP will be routed by Traefik
correctly based on SNI. DNS records are the access control.

### WireGuard tunnel design

The tunnel is **server-to-server** (VPS ↔ MikroTik), not client-facing:

```
VPS wg0:      10.100.0.1/30   (listens on UDP 51820)
MikroTik wg:  10.100.0.2/30   (PersistentKeepalive=25s — required to pierce CGNAT)

VPS peer entry for MikroTik:
  AllowedIPs = 10.100.0.2/32, 10.30.0.0/24
  (no Endpoint — MikroTik initiates, VPS accepts)

MikroTik peer entry for VPS:
  Endpoint = 89.167.62.126:51820
  AllowedIPs = 10.100.0.1/32
  PersistentKeepalive = 25
```

**Why PersistentKeepalive on MikroTik**: CGNAT mappings expire after ~30s of inactivity.
MikroTik sends a keepalive packet every 25s to keep the NAT entry alive, so the VPS
can always reach MikroTik even though MikroTik has no public IPv4.

**Why no PostUp/PreDown for the k8s VLAN route**: wg-quick automatically creates kernel
routes for each peer's AllowedIPs when the interface comes up. Adding the same route in
PostUp causes `RTNETLINK answers: File exists` and wg-quick fails to start. The route to
`10.30.0.0/24` is fully managed by wg-quick via `AllowedIPs`.

### Cloudflare DNS record

`jellyfin.ruddenchaux.xyz` → A → `89.167.62.126` (grey-cloud, DNS-only)

Grey-cloud is intentional:
- Cloudflare proxy would violate ToS section 2.8 (streaming media)
- DNS-only means Let's Encrypt sees the real VPS IP → cert issuance works
- Users connect directly to the VPS, not through Cloudflare's edge

The A record is created and kept updated by the `vps-relay` Ansible role
(`tasks/cloudflare-dns.yml`) using the Cloudflare API. Re-running the playbook
updates the IP if the VPS IP changes.

### MikroTik forwarding firewall rule

Traffic arriving from the WireGuard interface needs to be allowed to forward to
the k8s VLAN. RouterOS firewall rule (added by Ansible):

```
/ip firewall filter add
  chain=forward
  action=accept
  in-interface=wg-vps
  out-interface=vlan30-kubernetes
  comment=fw-wg-vps-fwd
```

MikroTik is already the default router for the k8s VLAN (10.30.0.0/24), so
once forwarding is allowed, it routes packets to the correct k8s worker via ARP.

### Ansible playbook

```bash
ansible-playbook ansible/playbooks/vps-relay.yml \
  -e cloudflare_api_token=<token> \
  -e cloudflare_zone_id=<zone_id>
```

Three-play design (required because VPS and MikroTik public keys must be exchanged
cross-play before WireGuard can complete the handshake):

1. **Play 1 — VPS**: UFW, WireGuard keypair, nginx stream proxy, Cloudflare A record.
   Writes wg0.conf without MikroTik peer (it's not known yet).
2. **Play 2 — MikroTik**: Creates `wg-vps` WireGuard interface (RouterOS auto-generates
   keypair), reads and exposes public key as a host fact, assigns `10.100.0.2/30`,
   adds VPS as peer using `hostvars['vps-relay']['wg_public_key']`.
3. **Play 3 — VPS**: Re-reads VPS private key, re-renders `wg0.conf` with MikroTik
   public key from `hostvars['mikrotik-gw']['mikrotik_wg_public_key']`, restarts
   WireGuard. Needs `vars_files` for role defaults since it's a standalone tasks play.

### Key files

| File | Purpose |
|------|---------|
| `ansible/playbooks/vps-relay.yml` | 3-play orchestration |
| `ansible/roles/vps-relay/` | VPS setup: UFW, WireGuard, nginx, Cloudflare DNS |
| `ansible/roles/vps-relay/templates/wg0.conf.j2` | WireGuard config (MikroTik peer + optional client peers) |
| `ansible/roles/vps-relay/templates/jellyfin-stream.conf.j2` | nginx TCP stream proxy config |
| `ansible/roles/mikrotik-wireguard/` | MikroTik: WireGuard interface, IP, peer, firewall |
| `ansible/inventory/group_vars/vps.yml` | VPS connection vars (ansible_user: root) |

---

## Implemented: Client VPN (Road Warrior)

Allows a phone or laptop to connect to the VPS via WireGuard and reach all homelab
services through the existing relay tunnel.

### Architecture

```
Android phone
       │ WireGuard (UDP 51820)
       │ AllowedIPs: 10.10.0.0/24, 10.20.0.0/24, 10.30.0.0/24 (split tunnel)
       ▼
VPS wg0 (10.100.0.1)
       │ IP forwarding + iptables MASQUERADE
       │ (Android traffic appears as 10.100.0.1 to MikroTik)
       ▼
WireGuard tunnel (existing, unchanged)
       ▼
MikroTik → VLAN 30 → Traefik → any service
```

### Why masquerade is needed

When Android (IP: `10.100.0.10`) sends a packet to Traefik (`10.30.0.200`):
1. VPS forwards it through wg0 to MikroTik
2. MikroTik receives `src=10.100.0.10, dst=10.30.0.200`
3. MikroTik has no route to `10.100.0.10` — it's not in the k8s VLAN or the
   WireGuard tunnel subnet it knows about
4. Response packet gets dropped

With `iptables MASQUERADE`:
1. Before forwarding, VPS rewrites `src=10.100.0.10` → `src=10.100.0.1`
2. MikroTik receives `src=10.100.0.1, dst=10.30.0.200` — it knows how to return to `10.100.0.1`
3. Response goes back to VPS wg0, which de-masquerades and forwards to Android
4. No MikroTik config change needed

The masquerade rule is in wg0.conf's `PostUp`/`PreDown`:
```
PostUp   = iptables -t nat -A POSTROUTING -s 10.100.0.0/24 -j MASQUERADE; ...
PreDown  = iptables -t nat -D POSTROUTING -s 10.100.0.0/24 -j MASQUERADE; ...
```

Using PostUp/PostDown in wg0.conf (not iptables-persistent) is correct here because
these are nat/filter rules that don't conflict with wg-quick's route management — unlike
the `ip route add` that caused the conflict for the relay tunnel.

### Split tunnel vs full tunnel

The client config uses **split tunnel** by default — only homelab traffic goes through VPN:
```
AllowedIPs = 10.10.0.0/24, 10.20.0.0/24, 10.30.0.0/24
```

Internet traffic stays local on the device (faster, no VPS bandwidth usage). Change to
`AllowedIPs = 0.0.0.0/0, ::/0` in the client config for full tunnel (all internet
via VPS). The conf is at `/etc/wireguard/clients/android.conf` on the VPS.

### What services become accessible via VPN

All homelab services via their internal IPs or via `*.ruddenchaux.xyz` (which resolves
publicly via Cloudflare to Traefik's IPv4 LB). Authentik ForwardAuth still applies — you
still need to log in via SSO for protected services. Jellyfin, Seerr, NZBGet use built-in
auth (no ForwardAuth).

Services accessible directly by internal IP:
- `10.10.0.2:8006` — Proxmox web UI
- `10.30.0.11-13` — k8s nodes (SSH, monitoring)
- Any VLAN 20 device (personal devices, NAS, etc.)

### Ansible playbook

```bash
# First device (Android):
ansible-playbook ansible/playbooks/vps-client-vpn.yml

# Additional device (separate keypair, different tunnel IP):
ansible-playbook ansible/playbooks/vps-client-vpn.yml \
  -e vpn_client_name=laptop \
  -e vpn_client_ip=10.100.0.11

# Re-run android after adding laptop (to merge both peers into wg0.conf):
ansible-playbook ansible/playbooks/vps-client-vpn.yml
```

The playbook prints a QR code at the end. In the Android WireGuard app:
**`+` → Create from QR code → scan**.

The wg0.conf template handles multiple devices: the `wg_client_peers` list in the template
renders one `[Peer]` block per client. Each re-run of the playbook reconstructs the full
wg0.conf from scratch (reads existing keys, builds peer list, renders template, hot-reloads
via `wg syncconf` — no tunnel interruption).

### Key files

| File | Purpose |
|------|---------|
| `ansible/playbooks/vps-client-vpn.yml` | Main playbook |
| `ansible/roles/vps-client-vpn/` | Keypair generation, IP forwarding, wg0 update, QR code |
| `ansible/roles/vps-client-vpn/tasks/keypair.yml` | Generate client keypair (idempotent) |
| `ansible/roles/vps-client-vpn/tasks/ip_forward.yml` | sysctl net.ipv4.ip_forward=1 |
| `ansible/roles/vps-client-vpn/tasks/peer.yml` | Render wg0.conf + wg syncconf hot-reload |
| `ansible/roles/vps-client-vpn/tasks/qrcode.yml` | qrencode + display QR + save .conf |
| `/etc/wireguard/clients/<name>.key` | Client private key (on VPS, mode 0600) |
| `/etc/wireguard/clients/<name>.conf` | Client WireGuard config (on VPS, for re-generating QR) |

---

## Prepared: IPv6 Stack (Not Yet Activated)

The full IPv6 infrastructure is coded and ready. It needs a real Starlink prefix to
complete Phase 2.

### How Starlink Provides IPv6

Starlink is in **bypass mode** — the Starlink hardware only provides power and physical
signal. MikroTik connects directly to the dish output.

Starlink provides two things over the WAN link:

**WAN /64 via SLAAC**: MikroTik's WAN interface gets a global IPv6 address automatically.

**LAN /56 via DHCPv6-PD**: Starlink delegates a `/56` prefix (256 × `/64` subnets).
Each VLAN gets its own `/64`. These are **public addresses** — every device that gets
one is directly reachable from the internet (MikroTik firewall is non-optional).

**Dynamic prefix**: The `/56` changes during Starlink maintenance windows (20:00–02:00 UTC),
dish reboots, and firmware updates. Dynamic DNS (external-dns) handles Cloudflare records
automatically. Cilium pool CIDR and MikroTik firewall rules need manual re-run of Phase 2.

### How DHCPv6-PD Works

DHCPv6-PD (Prefix Delegation, RFC 3633) — the router requests a block of IPv6 addresses
to distribute to downstream networks:

```
MikroTik (client)                    Starlink (server)
      │
      │--- Solicit (IA_PD, want prefix) --->
      │<-- Advertise (/56 available) -------
      │--- Request (give me that /56) ----->
      │<-- Reply (here is 2a0d:5600:X:Y::/56, T1=3600s) ---
      │
      │ (every T1 seconds: Renew → Reply)
```

RouterOS config:
```
/ipv6 dhcp-client add
  interface=ether1          # WAN port
  pool-name=starlink-pd     # pool name for carving /64s
  pool-prefix-length=64     # carve /64s from the /56
  request=prefix
  add-default-route=yes
```

Then per VLAN: `/ipv6 address add address=::1 from-pool=starlink-pd interface=vlan30-kubernetes`
RouterOS picks the next `/64`, assigns `<prefix>::1` as gateway, advertises via RA.

### How SLAAC Works

SLAAC (RFC 4862) — devices auto-configure IPv6 addresses from Router Advertisements:

1. MikroTik broadcasts an **RA** on each VLAN with the `/64` prefix and A=yes
2. Device takes the prefix + generates a 64-bit interface ID:
   - **EUI-64** (stable): derived from MAC. MAC `bc:24:11:1c:e2:8c` → `bc24:11ff:fe1c:e28c`
   - **Privacy extensions** (RFC 4941): random, changes periodically
3. Combines them: `2a0d:5600:abcd:0030:bc24:11ff:fe1c:e28c`

**Privacy extensions are disabled** (`use_tempaddr=0`) on k8s nodes so addresses are
stable for firewall rules, Cilium NDP announcements, and DNS records.

**`accept_ra=2` is required** on k8s nodes: Linux disables RA acceptance when IP
forwarding is on (assumes the machine is a router). k8s nodes need both — they
forward pod traffic AND accept upstream RAs. `accept_ra=2` overrides this.

### The Cloudflare Proxy Trick

When you orange-cloud (proxy) an AAAA record on Cloudflare:

```
Stored AAAA: service.ruddenchaux.xyz → 2a0d:5600:abcd:0030::200 (your IPv6)
Public DNS:  service.ruddenchaux.xyz → 104.21.x.x (A, Cloudflare edge)
                                      → 2606:4700::x (AAAA, Cloudflare edge)

IPv4 visitor → Cloudflare IPv4 edge → your IPv6 origin  ✓
IPv6 visitor → Cloudflare IPv6 edge → your IPv6 origin  ✓
```

Cloudflare acts as a free IPv4→IPv6 translation layer. Visitors never see your real address.

**Why only AAAA records via external-dns**: Traefik's IPv4 LB (`10.30.0.200`) is private —
Cloudflare can't reach it. external-dns is configured `--managed-record-types=AAAA,TXT`
to skip A records intentionally.

**Jellyfin exception**: Cloudflare ToS (section 2.8) prohibits proxying streaming media.
Use grey-cloud for Jellyfin. The VPS relay solves this for IPv4 users.

### Two-Phase Rollout

```bash
# Phase 1 — Infrastructure (MikroTik IPv6, k8s sysctl, external-dns secrets)
ansible-playbook ansible/playbooks/ipv6.yml --tags phase1 \
  -e cloudflare_api_token=<token>

# Check what prefix Starlink assigned to VLAN 30:
ssh debian@10.30.0.11 "ip -6 addr show scope global eth0"
# Example: 2a0d:5600:abcd:0030:bc24:11ff:fe1c:e28c/64
# Carve: 2a0d:5600:abcd:0030::200/122  (64 addresses for Cilium)

# Phase 2 — Kubernetes routing (Cilium pool + MikroTik Traefik forward rule)
ansible-playbook ansible/playbooks/ipv6.yml --tags phase2 \
  -e cilium_l2_ipv6_cidr="2a0d:5600:abcd:0030::200/122" \
  -e mikrotik_traefik_ipv6="2a0d:5600:abcd:0030::200"
```

After Phase 2, external-dns detects Traefik's new IPv6 LB and creates Cloudflare AAAA
records for every ingress. Services become reachable from IPv6 clients and (via
Cloudflare proxy) from all IPv4 clients too.

### NDP (IPv6 equivalent of ARP)

When MikroTik needs to forward a packet to Traefik's IPv6 LB:
```
MikroTik sends: Neighbor Solicitation (multicast) → "Who has 2a0d:..::200?"
Cilium replies:  Neighbor Advertisement → "2a0d:..::200 is at <worker MAC>"
```

Cilium handles NDP for all IPs in its LoadBalancer pool, same as it handles ARP for IPv4.

### MikroTik IPv6 Firewall

With IPv6, every device gets a globally routable address — no NAT. Firewall is mandatory.

```
# Forward chain — ONLY allow TCP 80/443 inbound to Traefik's specific IPv6
accept  established,related,untracked
drop    invalid
accept  icmpv6                                           # NDP must flow freely
accept  tcp dst=<TRAEFIK_IPv6>/128 dst-port=80,443 in=ether1  # ← only this
accept  in=LAN out=WAN                                   # outbound from LAN
drop                                                     # everything else
```

Port scanner hitting any k8s node's IPv6 directly gets dropped at MikroTik.

### Prefix Change Handling

When Starlink reassigns the /56:
1. MikroTik renews → VLAN interfaces get new /64s
2. k8s nodes get new SLAAC addresses within minutes
3. Cilium pool still has old CIDR → Traefik's LB IP becomes unreachable
4. external-dns detects LB IP changed → updates Cloudflare AAAA records
5. MikroTik forward rule still references old Traefik IPv6 → inbound fails

**Recovery**: re-run Phase 2 with new prefix values. Future improvement: a DaemonSet
that watches the node's SLAAC prefix and patches Cilium pool + MikroTik rule automatically.

### IPv6 key files

| File | Purpose |
|------|---------|
| `ansible/playbooks/ipv6.yml` | Phase 1 + Phase 2 orchestration |
| `ansible/roles/mikrotik-ipv6/` | DHCPv6-PD, RAs, IPv6 firewall on MikroTik |
| `ansible/roles/k8s-ipv6/` | sysctl accept_ra=2, use_tempaddr=0 on k8s nodes |
| `ansible/roles/cilium-l2/` | Cilium L2 pool (IPv4 + optional IPv6 CIDR via phase2) |
| `kubernetes/platform/traefik/values.yaml` | `ipFamilyPolicy: PreferDualStack` |
| `kubernetes/platform/external-dns/` | AAAA record automation via Cloudflare API |
| `kubernetes/apps/templates/external-dns.yaml` | ArgoCD Application for external-dns |

---

## Who Has IPv6? The Full Chain

Every link must support IPv6 for a visitor to use it:

```
ISP → Home Router → Device OS → Browser/App
 ↑
Most critical
```

**ISP**: Italy overall ~13% IPv6. Mobile (4G/5G) better than fixed. Iliad Italy: yes.
TIM/Vodafone mobile: partial. Fastweb FTTH: generally yes. Most ADSL: not yet.

**Home Router**: Must relay the prefix (DHCPv6-PD). ISP-provided routers often ship
with IPv6 disabled even when ISP supports it.

**Device OS**: Never the bottleneck today. Windows 10+, macOS, iOS, Android 4+ all
support IPv6 and prefer it via **Happy Eyeballs** (RFC 8305):
1. Start IPv6 connection, after 50ms also start IPv4 in parallel
2. Whichever connects first wins
3. Completely transparent to user

**To check a specific user**: visit **https://test-ipv6.com** — gives 0-10 score
with clear explanation.

---

## What Is and Isn't Exposed

### Currently exposed (A record → VPS)

| Domain | Via | Auth |
|--------|-----|------|
| `jellyfin.ruddenchaux.xyz` | VPS → WireGuard → Traefik | Jellyfin built-in |

### What nginx actually proxies

The nginx stream config is a **blind TCP passthrough** — it forwards ALL traffic on port
443 to Traefik, regardless of hostname. Traefik then routes by SNI/Host header.

This means: **any service becomes reachable by pointing its A record to the VPS IP**.
No nginx reconfiguration needed. The VPS is a generic TCP relay to your entire Traefik instance.

To expose another service:
1. Create a Cloudflare A record: `grafana.ruddenchaux.xyz → 89.167.62.126`
2. That's it — Traefik already serves grafana, nginx passes it through

Services behind Authentik ForwardAuth remain protected — SSO login still required.

### IPv6 (when Phase 2 is complete)

All services with Ingress objects will get AAAA records via external-dns, proxied through
Cloudflare (except Jellyfin which gets grey-cloud). Services will be reachable from any
IPv6 client and from all IPv4 clients via Cloudflare's proxy.

---

## Cloudflare Tunnel (Option C — Not Implemented, Available as Fallback)

If IPv6 turns out to be blocked by Starlink in this region:

```bash
# Deploy cloudflared as a k8s pod (outbound-only tunnel, no inbound ports needed)
kubectl apply -f kubernetes/apps/templates/cloudflared.yaml  # (not created yet)
```

Limitations:
- 100 MB upload limit per request → breaks Nextcloud, large file uploads
- ToS prohibits streaming → no Jellyfin
- Cloudflare terminates TLS → cert-manager certs not used publicly

Best as a temporary fallback while IPv6 is being debugged.

---

## Recommended Strategy

```
Step 1: VPS relay for Jellyfin          ← DONE
Step 2: Client VPN for personal access  ← DONE
Step 3: Run IPv6 Phase 1                ← Run when ready to test
Step 4: Test inbound IPv6 (python3 -m http.server on k8s node, curl from external IPv6)
Step 5a: If IPv6 works → Phase 2 → all services get AAAA records, Cloudflare proxy
Step 5b: If IPv6 blocked → Cloudflare Tunnel for remaining services (not Jellyfin)
Step 6: For additional IPv4 services → add A record pointing to VPS (nginx passes through)
```

---

## Lessons Learned

- **PostUp/PreDown route conflict**: Do NOT add `ip route add` in PostUp when AllowedIPs
  covers the same CIDR. wg-quick automatically creates routes from peer AllowedIPs.
  Adding the same route in PostUp causes `RTNETLINK: File exists` and wg-quick fails.
  PostUp/PostDown for iptables rules (masquerade, firewall) is fine.

- **PersistentKeepalive is non-optional** on the CGNAT side. Without it, the NAT entry
  expires in ~30s and the VPS can no longer initiate communication to MikroTik. The value
  must be less than the CGNAT timeout (25s is standard).

- **community.routeros requires paramiko**: Install with `pip3 install paramiko --user`.
  On Fedora Kinoite, `~/.local/lib/pythonX.Y/site-packages/` may be owned by root
  (immutable OS overlay artifact). Fix with `sudo chown -R $USER:$USER ~/.local/lib/`.

- **Multi-play Ansible variable scope**: `set_fact` facts from one play ARE available in
  subsequent plays via `hostvars`. But standalone plays (tasks: without roles:) don't load
  role defaults — add `vars_files` to load them explicitly.

- **wg syncconf for hot-reload**: `wg syncconf wg0 <(wg-quick strip /etc/wireguard/wg0.conf)`
  applies peer changes to the running interface without restarting the service. The existing
  MikroTik tunnel handshake is preserved. Use this in the client VPN role handler.
