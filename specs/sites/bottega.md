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

## Open decisions

- `TODO(decision):` exact Flynet static-IP terms (fixed lease vs. contractually
  guaranteed static — affects whether DDNS monitoring is needed).
- `TODO(decision):` physical move logistics/date, and whether there's a
  parallel-run period with Casa still hosting the lab (affects `MIGRATION.md`
  ordering).

## Acceptance criteria

- [ ] Bottega's WireGuard endpoint is reachable from Casa and the road-warrior
      peer (see `specs/network/wireguard.md`).
- [ ] Bottega's router management interface is unreachable from WAN.
- [ ] All services previously reachable at the home site are reachable
      identically once the lab is physically at Bottega (same hostnames, same
      internal resolution behavior).
