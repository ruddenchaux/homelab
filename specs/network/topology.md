# Topology: two-site hub-and-spoke

## Sites and roles

| Site | Connectivity | Public IP | Role |
|------|--------------|-----------|------|
| **Bottega** (Via Marconi, workspace) | Flynet PPPoE fiber | Static public IPv4 | **Hub** |
| **Casa** (home) | Starlink | CGNAT — no public IPv4 | **Spoke** |

The R740xd and the whole current lab (Proxmox, k8s cluster, ArgoCD, all
platform/media services) physically move to **Bottega**.

## Why Bottega is the hub

- Bottega has a static public IP: it can accept inbound WireGuard connections.
  Casa, behind CGNAT, structurally cannot — it can only dial out.
- The lab (compute, storage, all services) lives at Bottega after the move, so
  DNS, ingress (Traefik), and certificate issuance are naturally anchored there
  too. There is no reason to route service traffic through Casa.
- Consequence: Casa is a **spoke** — it initiates the tunnel to Bottega, and
  everything it needs to reach (or be reached from) goes through that tunnel.

## Why the VPS relay goes away

The Hetzner VPS relay (`ansible/roles/vps-relay`) exists solely to work around
CGNAT: it's a public IPv4 that both ends of a WireGuard tunnel could dial into.
Once Bottega has its own static public IP, it can terminate WireGuard directly
— the VPS's only job is fully replaced by Bottega's router. See `MIGRATION.md`
for the decommission plan (the VPS stays up until Bottega is verified working).

## Roles peers must fill

| Role | Site | Behavior |
|------|------|----------|
| Hub | Bottega MikroTik | Accepts inbound WireGuard from Casa and from the road-warrior peer. Routes between the lab LANs and remote peers. |
| Spoke | Casa MikroTik | Dials out to Bottega. Its own LAN must be reachable from Bottega (e.g. Home Assistant → local devices), and it must be administrable from Bottega. |
| Road-warrior | Phone (mobile WireGuard client) | Dials into Bottega (the hub); through the hub, can reach both Bottega's lab and Casa's LAN. |

## Addressing plan

The current VLAN plan **moves to Bottega** unchanged, since the lab moves there
as a physical unit:

| VLAN | Name | Subnet | Notes |
|------|------|--------|-------|
| 10 | Management | `10.10.0.0/24` | Proxmox, iDRAC |
| 20 | Trusted LAN | `10.20.0.0/24` | Personal devices, dev-box |
| 30 | Kubernetes | `10.30.0.0/24` | k8s VMs + pods |

Casa's LAN needs a **new, non-overlapping range** — it cannot reuse
`10.10.0.0/24` / `10.20.0.0/24` / `10.30.0.0/24` (rule: see `AGENTS.md` #2), and
it is a different physical LAN from the trusted-LAN VLAN that used to be the
home network.

Bottega's VLAN 1 (RouterOS default management/untagged network) is unchanged:
`192.168.88.0/24`, gw `192.168.88.1`.

Casa's LAN is renumbered to `192.168.90.0/24`, gw `192.168.90.1` — a single
flat LAN, no VLAN segmentation, since Casa no longer hosts the lab and only
needs to reach a small, fixed set of devices (energy-monitoring hardware, MQTT
broker — see `sites/casa.md`).

### Site-to-site addressing (authoritative — all other specs reference this table)

| Scope | Value |
|---|---|
| Bottega LAN / management (VLAN 1) | `192.168.88.0/24`, gw `192.168.88.1` — unchanged, RouterOS default |
| Bottega VLAN 10 (management) | `10.10.0.0/24`, gw `10.10.0.1` |
| Bottega VLAN 20 (trusted) | `10.20.0.0/24`, gw `10.20.0.1` |
| Bottega VLAN 30 (kubernetes) | `10.30.0.0/24`, gw `10.30.0.1` |
| Casa LAN | `192.168.90.0/24`, gw `192.168.90.1` — flat, renumbered from its prior range |
| Casa container network | `10.10.20.0/24`, gw `10.10.20.1` — the `containers` bridge carrying AdGuardHome (`10.10.20.2`), Casa's local DNS. Router-local and masqueraded; **not** carried over the tunnel and not in any peer's AllowedIPs. Listed here so it is never reused for a Bottega VLAN — note it does **not** overlap Bottega's `10.10.0.0/24`, which covers only `10.10.0.0`–`10.10.0.255` |
| WireGuard overlay (whole VPN) | `10.99.0.0/24` |
| — Bottega (hub) | `10.99.0.1/32` |
| — Casa (spoke) | `10.99.0.2/32` |
| — Road-warrior peers | `10.99.0.11/32` and upward |

The 10.x VLANs move physically from Casa to Bottega but keep their numbering.

### Reserved / forbidden ranges

- `100.64.0.0/10` must **never** be used anywhere in this design — it is
  Starlink's CGNAT space at Casa. Assigning it to any VLAN, LAN, or tunnel
  subnet would silently collide with Casa's own upstream WAN addressing.
- `192.168.90.0/24` (Casa LAN) and `192.168.88.0/24` (Bottega VLAN 1) must
  never overlap with each other or be reused for any other purpose.

### Tunnel parameters

- The hub (Bottega) listens on UDP `61536` on its static public IP. Casa and
  road-warrior peers are dial-out only and expose no listening port.
- Casa uses `PersistentKeepalive=25` to hold its CGNAT mapping open.
- WireGuard interface MTU is `1412`, with MSS clamping applied on the tunnel —
  Bottega's WAN is PPPoE (1492 MTU) and WireGuard's own overhead further
  reduces the usable payload size.

See `specs/network/wireguard.md` for the derived AllowedIPs table.

## Acceptance criteria

- [ ] `ip addr` / `ip route` on both MikroTiks show no subnet present on both
      sites' routing tables that isn't the deliberate tunnel subnet.
- [ ] A host on Casa's LAN can reach a host on Bottega's VLAN 30 (k8s) over the
      site-to-site tunnel, and the reverse direction also succeeds, with no
      overlapping-subnet routing ambiguity.
- [ ] `specs/network/topology.md` has zero `TODO(decision):` markers before the
      addressing plan is implemented in Ansible/Terraform.
