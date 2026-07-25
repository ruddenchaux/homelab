# Site: Bottega

## Role

**Hub.** Terminates WireGuard from Casa and the road-warrior peer. Is the
DNS/ingress entry point for all services. The only site directly reachable from
the internet.

## Connectivity

- Flynet PPPoE fiber, **static public IPv4**.
- Router: MikroTik, RouterOS 7.

## What lives here

The entire current lab moves here as a physical unit:

- Dell R740xd (Proxmox host), full k8s cluster (control plane + workers)
- All platform/media/app services currently deployed via ArgoCD
- VLANs 10 (mgmt), 20 (trusted LAN), 30 (kubernetes) — see
  `specs/network/topology.md`

## Responsibilities as hub

- Accept inbound WireGuard from Casa (spoke) and the road-warrior peer.
- Route traffic between remote peers and the appropriate local VLAN, per
  `specs/network/firewall.md`.
- Own the public DNS-facing IP for any service that needs raw-internet
  exposure (`specs/network/dns-exposure.md`).
- Never expose its own router management interface to WAN
  (`AGENTS.md` rule #5) — the static IP is for the WireGuard/service path
  only.

## Connectivity fact

Bottega's public IP is contractually static: `145.11.24.43`. No DDNS or
mitigation is needed for IP instability; the only ongoing concern is
reachability monitoring, tracked as `TODO(fact):` in
`specs/observability/external-checks.md`, not here.

## Move logistics

Decided: a parallel run at both sites, with cutover only after Bottega passes
its acceptance criteria below. No live migration — power down at Casa, move
the hardware, power up at Bottega. See `MIGRATION.md` for the full ordering.

- `TODO(fact):` move date — not yet scheduled, non-blocking.

## Acceptance criteria

- [ ] Bottega's WireGuard endpoint is reachable from Casa and the road-warrior
      peer (see `specs/network/wireguard.md`).
- [ ] Bottega's router management interface is unreachable from WAN.
- [ ] All services previously reachable at the home site are reachable
      identically once the lab is physically at Bottega (same hostnames, same
      internal resolution behavior).
