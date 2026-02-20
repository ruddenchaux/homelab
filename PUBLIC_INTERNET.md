# Public Internet Access

Reference document explaining how and why homelab services are exposed to the internet,
including detailed explanations of the underlying protocols.

---

## The Problem: Starlink CGNAT

Starlink Residential Lite provides no public IPv4 address. The connection sits behind
**CGNAT** (Carrier-Grade NAT): many customers share the same public IPv4, so inbound
connections to your home are impossible on IPv4.

IPv6 is the way out. Starlink provides full public IPv6 connectivity.

---

## Options Evaluated

| Option | Cost | Pros | Cons |
|--------|------|------|------|
| **VPS + WireGuard** | ~4 €/month | Full IPv4+IPv6, any protocol, full control | Costs money, extra latency hop |
| **IPv6 + Cloudflare proxy** | Free | Zero cost, educational | Dynamic prefix, ~13% IT IPv6, Jellyfin TOS issue |
| **Cloudflare Tunnel** | Free | No inbound ports, works through CGNAT | 100 MB upload limit, TOS prohibits streaming |
| Tailscale Funnel | Free | Simple | No custom domains, breaks Authentik cookie domain |
| ngrok | $8+/month | Simple | Too expensive |

**Chosen**: IPv6 direct + Cloudflare proxy (Option B), with VPS+WireGuard as a documented
fallback (Option A). See the Recommended Strategy section at the end.

---

## How Starlink Provides IPv6

Starlink is in **bypass mode** — the Starlink hardware (dish + adapter) only provides
power and the physical signal. MikroTik is the actual router, connected directly to
the Starlink dish output via a network port.

Starlink provides two things over the WAN link:

### WAN /64 via SLAAC
The WAN interface of MikroTik gets a global IPv6 address via SLAAC (see below).
This is the router's "internet-facing" address.

### LAN /56 via DHCPv6-PD (Prefix Delegation)
Starlink delegates a `/56` prefix to your router. A `/56` contains 256 `/64` subnets,
one of which can be assigned to each internal VLAN/network.

This is the prefix your internal devices use. It is **public** — every device that
gets an address from it is directly reachable on the internet (which is why IPv6
firewalling is non-optional).

### Dynamic prefix
The `/56` prefix is **not static**. It changes during:
- Starlink scheduled maintenance windows (20:00–02:00 UTC)
- Dish reboots
- Firmware updates

When it changes, all internal IPv6 addresses change. SLAAC re-advertises within minutes,
but any hardcoded references (Cilium pool CIDR, MikroTik firewall rules) need updating.
DDNS (via external-dns) handles the Cloudflare records automatically.

---

## How DHCPv6-PD Works

DHCPv6-PD (Prefix Delegation, RFC 3633) is the protocol by which a router requests
a block of IPv6 addresses to distribute to its downstream networks.

```
MikroTik (client)                    Starlink (server)
      |                                     |
      |--- Solicit (IA_PD, want prefix) --->|
      |<-- Advertise (/56 available) -------|
      |--- Request (give me that /56) ----->|
      |<-- Reply (here is 2a0d:5600:X:Y::/56, T1=3600s) ---|
      |                                     |
      | (every T1 seconds)                  |
      |--- Renew ------------------------------>|
      |<-- Reply (renewed) ------------------|
```

The MikroTik RouterOS configuration:
```
/ipv6 dhcp-client add
  interface=ether1          # WAN port
  pool-name=starlink-pd     # name for the pool of delegated prefixes
  pool-prefix-length=64     # carve /64s from the delegated /56
  request=prefix            # we want a prefix, not an address
  add-default-route=yes     # install IPv6 default route via Starlink
```

`pool-prefix-length=64` tells RouterOS: "when I need to assign a prefix to an interface,
cut a `/64` out of the delegated `/56`". RouterOS automatically picks the next available
`/64` for each interface that requests one from this pool.

Then for each VLAN:
```
/ipv6 address add
  address=::1
  from-pool=starlink-pd
  interface=vlan30-kubernetes
```

RouterOS picks the next `/64` from the pool, assigns `<prefix>::1` as the gateway
address on that interface, and starts advertising it via RA.

---

## How SLAAC Works

SLAAC (Stateless Address Autoconfiguration, RFC 4862) lets devices configure their own
IPv6 addresses without a DHCPv6 server.

### Router Advertisements (RA)
The router (MikroTik) periodically broadcasts **Router Advertisements** on each LAN
interface. An RA contains:
- **Prefix information**: the `/64` prefix devices should use
- **A flag** (Autonomous): if set, devices generate their own address using this prefix
- **M flag** (Managed): if set, devices should use DHCPv6 for addresses (we use M=no)
- **O flag** (Other config): if set, devices use DHCPv6 for other info like DNS (we use O=yes)
- **DNS servers**: Cloudflare IPv6 resolvers (`2606:4700:4700::1111`)
- **MTU**: hint for the path MTU (1460 for Starlink headroom)

### Address Generation
When a device receives an RA with a prefix (e.g. `2a0d:5600:abcd:0030::/64`) and A=yes:

1. Takes the `/64` prefix: `2a0d:5600:abcd:0030`
2. Generates a 64-bit interface ID — two methods:
   - **EUI-64** (stable): derived from the MAC address. Example: MAC `bc:24:11:1c:e2:8c`
     → insert `ff:fe` in the middle → `be:24:11:ff:fe:1c:e2:8c` → flip bit 6 → `bc24:11ff:fe1c:e28c`
   - **Privacy extensions** (RFC 4941): random interface ID, changes periodically
3. Combines them: `2a0d:5600:abcd:0030:bc24:11ff:fe1c:e28c`

**We disable privacy extensions** (`use_tempaddr=0`) on k8s nodes. Reason: the address
must be stable so that:
- MikroTik firewall rules can reference it
- Cilium NDP announcements work correctly
- DNS records remain valid between RA cycles

### Why `accept_ra=2` on k8s Nodes
Linux has a rule: if IP forwarding is enabled (`net.ipv4.ip_forward=1`), the kernel
assumes the machine is a router and sets `accept_ra=0` — it will NOT accept Router
Advertisements from upstream.

k8s nodes have forwarding enabled for pod-to-pod routing. Without the fix, they would
never get a global IPv6 address even though MikroTik is sending RAs.

`accept_ra=2` overrides this: "accept RAs even though forwarding is on". This is the
correct setting for dual-role machines (both routing pods and accepting upstream RAs).

---

## The Cloudflare Proxy Trick

This is the key insight that makes IPv6-only origins work for 100% of visitors.

### Without proxy (grey-cloud, DNS-only)
```
AAAA record: jellyfin.ruddenchaux.xyz → 2a0d:5600:abcd:0030::200

IPv6 visitor → resolves AAAA → connects directly to your IPv6 → works ✓
IPv4 visitor → no A record   → DNS failure or "cannot connect"    ✗
```

### With proxy (orange-cloud)
```
AAAA record: service.ruddenchaux.xyz → 2a0d:5600:abcd:0030::200 (stored by Cloudflare)
Public DNS:  service.ruddenchaux.xyz → 104.21.x.x (A)   ← Cloudflare's edge IP
                                     → 2606:4700::x (AAAA) ← Cloudflare's edge IP

IPv4 visitor → resolves A    → Cloudflare IPv4 edge → Cloudflare connects to your IPv6 origin → works ✓
IPv6 visitor → resolves AAAA → Cloudflare IPv6 edge → Cloudflare connects to your IPv6 origin → works ✓
```

Cloudflare acts as an **IPv4-to-IPv6 translation layer at the edge**, for free.
Visitors never see your real IPv6 address — they connect to Cloudflare's infrastructure.

### Why only AAAA records are published
Traefik also has an IPv4 LoadBalancer IP (`10.30.0.200`, from Cilium's L2 pool).
This is a **private** address — publishing it to public DNS would be pointless (Cloudflare
can't reach `10.30.0.200` from the internet). external-dns is configured with
`--managed-record-types=AAAA,TXT` to only create AAAA records, deliberately skipping A.

### Jellyfin exception
Cloudflare's ToS (section 2.8) prohibits using their proxy for video/audio streaming.
This is actively enforced for high-bandwidth users. For Jellyfin:

- **Option 1 (grey-cloud)**: AAAA only, no proxy. IPv6 users (~13% in Italy) can stream
  directly. IPv4 users cannot reach it.
- **Option 2 (VPS + WireGuard)**: ~4€/month Hetzner VPS, WireGuard tunnel, VPS reverse-proxies
  only Jellyfin traffic. Full IPv4+IPv6, no TOS issue.
- **Option 3 (proxy anyway)**: Low risk for a handful of family users. Cloudflare enforces
  against large-scale abuse, not 2-3 people streaming.

---

## Who Has IPv6? The Full Chain

Every link in the chain must support IPv6:

```
ISP → Home Router → Device OS → Browser/App
 ↑
Most critical gatekeeper
```

### ISP (biggest variable)
- Must own IPv6 address space (allocated by RIPE) and have it routed
- Italy overall: ~13% IPv6 adoption
- **Mobile (4G/5G)**: generally better — operators adopted IPv6 faster due to IPv4 exhaustion
  hitting mobile harder (millions of SIMs). Iliad Italy: yes. TIM/Vodafone mobile: partial.
- **Fixed broadband**: heavily ISP-dependent. Fastweb: generally yes. TIM FTTH: rolling out.
  Most ADSL/VDSL customers: often not yet.

### Home Router
- Must support IPv6 (all post-2015 routers do hardware-wise)
- Must have it enabled — ISP-provided routers often ship with IPv6 disabled or
  misconfigured even when the ISP supports it
- Must relay the prefix to LAN devices (DHCPv6-PD or static /64 assignment)

### Device OS
Almost never the issue today. Windows 10+, macOS 10.7+, iOS, Android 4+, Linux all
support IPv6 and actually **prefer it** via the Happy Eyeballs algorithm (RFC 8305):

```
Browser opens connection to service.ruddenchaux.xyz (has both A and AAAA records):
1. Starts IPv6 connection attempt
2. After 50ms delay, starts IPv4 attempt in parallel
3. Whichever connects first wins (usually IPv6 if available, since it has the head start)
4. Other connection is cancelled
```

This is completely transparent to the user. If they have working IPv6, they use it
automatically without knowing.

### How to Check if a Specific User Has IPv6
They visit **https://test-ipv6.com** — gives a clear 0/10 score and explains exactly
what works and what doesn't for their current connection (home Wi-Fi, mobile data, etc.
are different — each has its own IPv6 status).

---

## Kubernetes Integration (Minimal Changes)

The principle: **don't rebuild the cluster for dual-stack**. IPv6 is added only as
an external entry point. Everything internal stays IPv4.

```
Internet (IPv6) → MikroTik → Traefik LB (IPv6) → ClusterIP (IPv4) → Pods (IPv4)
                                    ↑
                           Only this gets IPv6
```

### What changed
1. **Traefik**: `ipFamilyPolicy: PreferDualStack` → gets both IPv4 LB (10.30.0.200)
   and IPv6 LB (from Cilium pool) assigned by k8s
2. **Cilium**: `ipv6.enabled=true` + IPv6 CIDR added to `CiliumLoadBalancerIPPool`
   → Cilium announces Traefik's IPv6 via **NDP** (the IPv6 equivalent of ARP)
3. **external-dns**: watches Ingress objects, publishes AAAA records to Cloudflare

### What did NOT change
- Pod networking (all IPv4)
- Service ClusterIPs (all IPv4)
- CoreDNS (all IPv4)
- Any existing service configuration

### NDP (Neighbor Discovery Protocol)
NDP is the IPv6 equivalent of ARP. When MikroTik receives a packet destined for
Traefik's IPv6 LB address and needs to forward it to a k8s worker:

```
MikroTik: "Who has 2a0d:5600:abcd:0030::200? Tell me at fe80::1"
          ← Neighbor Solicitation (multicast)

Cilium:   "2a0d:5600:abcd:0030::200 is at bc:24:11:1c:e2:8c"
          ← Neighbor Advertisement (from the worker running Cilium)
```

Cilium handles NDP responses for all LoadBalancer IPs in its pool, exactly as it
handles ARP for IPv4 L2 announcements.

---

## external-dns

**external-dns** is a Kubernetes add-on that watches Ingress objects and automatically
creates/updates DNS records. It removes the need to manually manage Cloudflare records.

```
Ingress (jellyfin.ruddenchaux.xyz) ──→ external-dns ──→ Cloudflare API
                                           reads           creates AAAA
                                       Traefik's IPv6 LB
```

Key configuration:
```yaml
sources: [ingress]                       # read from Ingress objects
domainFilters: [ruddenchaux.xyz]         # only manage this domain
extraArgs:
  - --managed-record-types=AAAA          # only AAAA records (no A)
  - --managed-record-types=TXT           # TXT for ownership tracking
cloudflare.proxied: true                 # orange-cloud by default
txtOwnerId: homelab-k8s                  # prevents touching manually-created records
policy: sync                             # delete stale records when ingresses disappear
```

The **TXT records** are how external-dns tracks ownership. Before creating/updating
a record, it checks for a `TXT` record like:
```
_external-dns.jellyfin.ruddenchaux.xyz → "heritage=external-dns,owner=homelab-k8s"
```
This prevents it from touching records it didn't create (e.g. MX records, manual entries).

---

## MikroTik IPv6 Firewall

With IPv6, every device gets a **globally routable public address** — there is no NAT.
Without a firewall, every pod, every k8s node, and every home device would be directly
reachable from the internet.

### Input chain (traffic TO the router itself)
```
accept  connection-state=established,related,untracked  # return traffic
drop    connection-state=invalid
accept  protocol=icmpv6                                  # NDP, ping, etc. — must not block
accept  protocol=udp dst-port=546 src=fe80::/10         # DHCPv6 replies from Starlink
drop    in-interface-list=!LAN                           # drop everything else from WAN
```

### Forward chain (traffic THROUGH the router)
```
accept  connection-state=established,related,untracked  # return traffic
drop    connection-state=invalid
accept  protocol=icmpv6                                  # NDP must flow freely
accept  protocol=tcp dst=<TRAEFIK_IPv6>/128 dst-port=80,443 in-interface=ether1  # ← KEY RULE
accept  in-interface-list=LAN out-interface-list=WAN    # LAN devices can reach internet
drop                                                     # everything else blocked
```

The key rule: **only TCP 80/443 from WAN to Traefik's specific IPv6 address** is
allowed inbound. No other service is reachable from the internet, regardless of its
IPv6 address. A port scanner hitting a k8s node's IPv6 directly gets dropped at
MikroTik before the packet even enters the network.

---

## Two-Phase Rollout

### Phase 1 — Infrastructure
```bash
ansible-playbook ansible/playbooks/ipv6.yml --tags phase1 \
  -e cloudflare_api_token=<token>
```

Actions:
- MikroTik: DHCPv6-PD client, /64 per VLAN, SLAAC RAs, IPv6 firewall (except Traefik rule)
- k8s nodes: sysctl `accept_ra=2` + `use_tempaddr=0`
- Creates `external-dns` namespace + Cloudflare token secret in k8s

After Phase 1, check what prefix Starlink assigned to VLAN 30:
```bash
ssh debian@10.30.0.11 "ip -6 addr show scope global eth0"
# Example output:
# inet6 2a0d:5600:abcd:0030:bc24:11ff:fe1c:e28c/64 scope global dynamic mngtmpaddr
#        ^^^^^^^^^^^^^^^^^^^^^^^^ this is your /64 prefix for VLAN 30
```

Carve an IPv6 block for Cilium. Example: take `::200/122` from that /64
(a /122 gives 64 addresses: `::200` through `::23f`):
```
Prefix from VLAN 30: 2a0d:5600:abcd:0030::/64
Cilium block:        2a0d:5600:abcd:0030::200/122
Traefik LB will get: 2a0d:5600:abcd:0030::200  (first address in block)
```

### Phase 2 — Kubernetes routing
```bash
ansible-playbook ansible/playbooks/ipv6.yml --tags phase2 \
  -e cilium_l2_ipv6_cidr="2a0d:5600:abcd:0030::200/122" \
  -e mikrotik_traefik_ipv6="2a0d:5600:abcd:0030::200"
```

Actions:
- Updates `CiliumLoadBalancerIPPool` with the IPv6 CIDR → Traefik gets its IPv6 LB
- Adds MikroTik forward rule for TCP 80/443 to Traefik's specific IPv6

After Phase 2, external-dns detects Traefik's new IPv6 LB and creates AAAA records
in Cloudflare for every ingress hostname. Services become publicly accessible.

---

## Handling Prefix Changes

When Starlink reassigns the /56 (during maintenance, reboot, etc.):

1. MikroTik gets new prefix via DHCPv6-PD renewal → VLAN interfaces get new /64s
2. RA re-advertises → k8s nodes get new SLAAC addresses within minutes
3. Cilium pool still has the OLD CIDR → Traefik's LB IP is no longer routable
4. external-dns detects Traefik's LB IP changed → updates Cloudflare AAAA records
5. MikroTik forward rule still references old Traefik IPv6 → inbound traffic fails

**Recovery**: re-run Phase 2 with the new prefix values (step 5 fix), after confirming
the new VLAN 30 prefix from the node.

**Future improvement**: a DaemonSet or CronJob that watches the node's SLAAC prefix,
computes the new Cilium pool CIDR and Traefik IP, and patches both automatically.

---

## Recommended Strategy

```
1. Phase 1 + Phase 2 → verify IPv6 works inbound (curl -6 https://service.ruddenchaux.xyz)
2. If Starlink blocks inbound IPv6 in your area → Cloudflare Tunnel as fallback (outbound-only)
3. If Jellyfin IPv4 access becomes a real need → add VPS + WireGuard for that service only
```

### VPS + WireGuard fallback (Option A)
Hetzner CX22 in Nuremberg (~15ms from Milan), ~4€/month:
- WireGuard tunnel: VPS public IP ↔ MikroTik (PersistentKeepalive=25 — required for CGNAT)
- Internet → VPS (public IPv4) → WireGuard → MikroTik → Traefik → pods
- Fully transparent to existing Traefik + Authentik + cert-manager stack (cert-manager
  uses DNS-01, never needs inbound connections)
- Can be used for all services or just Jellyfin (hybrid)

### Cloudflare Tunnel fallback (Option C)
- `cloudflared` pod in k8s (outbound tunnel to Cloudflare edge)
- Works through CGNAT without any IPv6 or port opening
- 100 MB upload limit per request (breaks Nextcloud, large file uploads)
- ToS prohibits streaming (Jellyfin)
- Cloudflare terminates TLS (your cert-manager certs not used publicly)
- Best as a temporary fallback while troubleshooting IPv6

---

## Key Files

| File | Purpose |
|------|---------|
| `ansible/playbooks/ipv6.yml` | Orchestration — run Phase 1 then Phase 2 |
| `ansible/roles/mikrotik-ipv6/` | DHCPv6-PD, RAs, firewall on MikroTik |
| `ansible/roles/k8s-ipv6/` | sysctl for accept_ra=2 + use_tempaddr=0 on k8s nodes |
| `ansible/roles/cilium-l2/` | Cilium L2 pool (IPv4 + optional IPv6 CIDR) |
| `kubernetes/platform/traefik/values.yaml` | PreferDualStack service configuration |
| `kubernetes/platform/external-dns/` | AAAA record automation via Cloudflare API |
| `kubernetes/apps/templates/external-dns.yaml` | ArgoCD Application for external-dns |
