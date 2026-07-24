# Site: Casa

## Role

**Spoke.** Dials out to Bottega (the hub); can never accept inbound
connections directly, since it sits behind CGNAT. After the lab moves to
Bottega, Casa hosts only home-local devices/services (e.g. Home Assistant's
local integrations, energy monitoring hardware — see `HOME_ASSISTANT.md`).

## Connectivity

- Starlink Residential Lite, **CGNAT** — no public IPv4, structurally cannot
  accept inbound WireGuard (same constraint that originally drove the VPS relay
  design; see `PUBLIC_INTERNET.md` for the CGNAT explanation, which still
  applies to Casa specifically now).
- Router: MikroTik, RouterOS 7.

## Requirements this site must satisfy

- Dial out to Bottega and keep the tunnel alive (`PersistentKeepalive`, same
  mechanism as the retired VPS tunnel — see `specs/network/wireguard.md`).
- Its LAN must be reachable **from** Bottega (Home Assistant, running in the
  k8s cluster at Bottega, needs to reach local devices at Casa — e.g. the
  EmonTx4/EmonBase energy-monitoring hardware, MQTT broker).
- Must be administrable **from** Bottega (remote config changes to Casa's
  MikroTik, without a physical visit) — this is exactly the scenario
  `AGENTS.md` rule #4 (safe-mode) is written for, since a bad rule here can
  lock out the only remote path back in.

## What no longer lives here

Once the physical move happens: Proxmox, the k8s cluster, and all currently
home-hosted services move to Bottega. Casa keeps no lab compute after cutover
(see `MIGRATION.md` for the transition order).

## Open decisions

- `TODO(decision):` Casa's LAN subnet (must be non-overlapping with Bottega's
  VLANs — rule #2).
- `TODO(decision):` whether Casa keeps any VLAN segmentation of its own, or
  runs a single flat LAN now that it's not hosting the lab.
- `TODO(decision):` inventory of what stays at Casa long-term (energy
  monitoring hardware confirmed via `HOME_ASSISTANT.md`; anything else?).

## Acceptance criteria

- [ ] Casa's WireGuard tunnel to Bottega is up and self-heals after a Casa
      router reboot (dial-out is automatic, no manual intervention).
- [ ] A device on Casa's LAN (e.g. the EmonBase) is reachable from Home
      Assistant running at Bottega.
- [ ] An admin at Bottega can apply a RouterOS change to Casa's router over the
      tunnel and it takes effect, without needing physical access to Casa.
