# Public Internet Access

Reference document explaining how and why homelab services are exposed to the internet,
including detailed explanations of the underlying protocols and everything that was
implemented and why.

---

## The Problem: Starlink CGNAT

Starlink Residential Lite provides no public IPv4 address. The connection sits behind
**CGNAT** (Carrier-Grade NAT): many customers share the same public IPv4, so inbound
connections to your home are impossible on IPv4.

---

## Options Evaluated

| Option | Cost | Pros | Cons |
|--------|------|------|------|
| **VPS + WireGuard** | ~4 €/month | Any protocol, full control, streaming OK | Costs money, extra latency hop |
| Cloudflare Tunnel | Free | No inbound ports, works through CGNAT | 100 MB upload limit, TOS prohibits streaming |
| Tailscale Funnel | Free | Simple | No custom domains (only *.ts.net), breaks Authentik cookie |
| ngrok | $8+/month | Simple | Too expensive |

**What was implemented**:
- **VPS + WireGuard**: **Deployed** — Hetzner VPS as TCP stream relay, WireGuard tunnel
  to MikroTik, nginx passthrough. `jellyfin.ruddenchaux.xyz` live.
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
