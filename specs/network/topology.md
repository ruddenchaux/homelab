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

- `TODO(decision):` Casa LAN subnet (single flat LAN, or does Casa need its own
  VLAN segmentation too?).
- `TODO(decision):` site-to-site WireGuard tunnel subnet (distinct from the old
  `10.100.0.0/24` VPS-tunnel range, or reused now that the VPS is gone — needs
  an explicit decision either way).
- `TODO(decision):` road-warrior WireGuard client address pool.
- `TODO(decision):` whether Casa keeps any local VLAN trunking (MikroTik at
  Casa) or runs a single flat LAN, given it no longer hosts the lab.

## Acceptance criteria

- [ ] `ip addr` / `ip route` on both MikroTiks show no subnet present on both
      sites' routing tables that isn't the deliberate tunnel subnet.
- [ ] A host on Casa's LAN can reach a host on Bottega's VLAN 30 (k8s) over the
      site-to-site tunnel, and the reverse direction also succeeds, with no
      overlapping-subnet routing ambiguity.
- [ ] `specs/network/topology.md` has zero `TODO(decision):` markers before the
      addressing plan is implemented in Ansible/Terraform.
