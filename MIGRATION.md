# Migration: single-site (Casa + VPS relay) → two-site (Bottega hub, Casa spoke)

This document tracks what the two-site architecture makes obsolete. Nothing
listed here is deleted yet — see "Safe order of removal" for when each piece
can actually go.

## Why this migration

Casa (home) sits behind Starlink CGNAT and can never accept inbound
connections, which is why the Hetzner VPS relay exists today. Bottega (new
workspace) has a static public IP on Flynet fiber — once the lab moves there,
Bottega can terminate WireGuard directly and be the internet-facing hub, making
the VPS relay's entire purpose redundant. See `specs/network/topology.md` for
the full rationale.

## Obsolete components

### `ansible/roles/vps-relay` + `ansible/playbooks/vps-relay.yml`

- **What it does today**: provisions the Hetzner VPS (UFW, WireGuard `wg0`,
  nginx TCP-stream passthrough, Cloudflare DNS for the exposed service).
  Terminates the WireGuard tunnel from home's MikroTik and relays public TCP
  443/80 traffic to Traefik through the tunnel.
- **Why it's obsolete**: its only job is to give a CGNAT'd home a public IPv4
  presence. Bottega has one natively.
- **What replaces it**: Bottega's MikroTik terminates WireGuard directly (see
  `specs/network/wireguard.md`), and dst-nat rules on Bottega's router forward
  public ports straight to Traefik (see `specs/network/dns-exposure.md`) —
  same blind-passthrough principle, no VPS hop.
- **Safe removal order**: keep the VPS running and the tunnel intact until
  Bottega's hub role is verified end-to-end (public DNS records repointed,
  dst-nat working, certificates issuing) — i.e. until the physical move is
  complete and confirmed, not just planned. Only then decommission the VPS.

### `ansible/roles/vps-client-vpn` + `ansible/playbooks/vps-client-vpn.yml`

- **What it does today**: generates a road-warrior WireGuard peer that
  terminates on the VPS, masquerades traffic so it can reach the homelab VLANs
  through the existing VPS↔MikroTik tunnel.
- **Why it's obsolete**: the road-warrior peer can terminate directly on
  Bottega's MikroTik once Bottega has a static IP — no relay/masquerade hop
  needed for the Bottega leg. See `.claude/skills/add-wg-road-warrior.md` for
  the new procedure.
- **What replaces it**: a WireGuard peer added directly to Bottega's MikroTik,
  with forwarding rules to whichever subnets (Bottega's own, and/or Casa's
  through the site-to-site tunnel) the peer needs.
- **Safe removal order**: existing road-warrior devices should be
  re-provisioned against Bottega's hub and verified working *before* the VPS
  peer is removed, so there's no gap in the ability to administer the lab
  remotely during the transition.

### `ansible/roles/mikrotik-wireguard` (VPS-relay-oriented form)

- **What it does today**: configures the home MikroTik's `wg-vps` interface,
  address, peer (pointing at the VPS), and the `fw-wg-vps-fwd` forwarding rule
  — i.e. MikroTik acting as a **spoke dialing out to the VPS**.
- **Why it's partly obsolete**: under the new architecture, **Bottega's**
  MikroTik plays the opposite role — a **hub accepting inbound** connections
  from Casa and the road-warrior. The role's shape (interface/address/peer/
  firewall tasks) is reusable, but the direction and defaults
  (`mikrotik_wg_address: 10.100.0.2/30`, `vps_wg_ip` hardcoded) are
  VPS-relay-specific and need to become site-aware (hub vs. spoke behavior)
  rather than being deleted outright.
- **What replaces it**: the same role, generalized to configure either a hub
  (Bottega) or a spoke (Casa) WireGuard interface — not a new role, an
  evolution of this one. This generalization is implementation work, out of
  scope for this restructuring task.
- **Safe removal order**: N/A — this role isn't removed, it's extended. Keep
  the existing VPS-oriented task files working until the generalized version
  is verified against Bottega, then retire the VPS-specific defaults.

### `PUBLIC_INTERNET.md` (as a forward-looking design doc)

- **What it does today**: explains why the VPS relay + client VPN exist and
  how they work — accurate and worth keeping as historical reference for the
  CGNAT/WireGuard mechanics (PersistentKeepalive, PostUp route conflicts,
  masquerade) that still apply at Casa going forward.
- **Why it's obsolete as forward guidance**: describes a single-site
  (Casa-only) design that the two-site architecture supersedes for anything
  about *public* exposure. The CGNAT/WireGuard mechanics sections remain
  correct and applicable to Casa specifically.
- **What replaces it**: `specs/network/topology.md`, `specs/network/wireguard.md`,
  and `specs/network/dns-exposure.md` are authoritative for the target design.
  `PUBLIC_INTERNET.md` stays as reference/history, marked accordingly.
- **Safe removal order**: no removal — it's reference material, not active
  config. Revisit whether to archive it once the VPS is actually decommissioned.

### Cloudflare A record: `jellyfin.ruddenchaux.xyz → 89.167.62.126` (VPS IP)

- **What it does today**: routes public Jellyfin traffic to the VPS relay.
- **Why it's obsolete**: once Bottega has a dst-nat rule forwarding to Traefik,
  the record should point at Bottega's static IP instead.
- **What replaces it**: an A record to Bottega's static IP, managed the same
  way (Cloudflare API via Ansible), per `specs/network/dns-exposure.md`.
- **Safe removal order**: only repoint DNS after Bottega's dst-nat path is
  verified working (test with a temporary hostname or low TTL before cutting
  over the live one), to avoid a public outage window.

## Not obsolete — unchanged by this migration

- `ansible/roles/mikrotik-vlans`, `mikrotik-guest-cleanup`: VLAN plan moves to
  Bottega as-is; these apply there unchanged.
- Everything in `kubernetes/`, and the k8s-related Ansible roles/playbooks:
  the cluster moves physically but its configuration doesn't change because of
  this migration.
- `SECURITY.md`, `TROUBLESHOOTING.md`: stay as reference; update in a future
  change once the new architecture is actually implemented and its own
  gotchas are known.
