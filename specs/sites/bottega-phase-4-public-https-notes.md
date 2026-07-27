# Bottega Phase 4: Operational Conversation Digest

This note records the outcome of the Phase 4 public HTTPS cutover work in
plain language. It is not a replacement for
`specs/sites/bottega-phase-4-public-https.md`; the phase spec remains the
source of truth for requirements and rollback.

## What was done

- Added the Phase 4 RouterOS/Ansible implementation for direct public HTTPS
  forwarding from Bottega to Traefik at `10.30.0.200:443`.
- Verified the router path externally before changing production DNS.
- Cut over the Cloudflare A records for:
  - `jellyfin.ruddenchaux.xyz`
  - `ha.ruddenchaux.xyz`
  - `immich.ruddenchaux.xyz`
  to `145.11.24.43` with DNS-only records and TTL 60.
- Kept the VPS relay and rollback path available during the transition.

## Final state

- Public HTTPS terminates on Traefik behind Bottega’s WAN `443` forward.
- RouterOS management services remain LAN/VPN-only.
- Split DNS on the router keeps `*.ruddenchaux.xyz` resolving to
  `10.30.0.200` for internal clients.
- Cloudflare no longer points the three public hostnames at the old VPS IP.

## Validation performed

- RouterOS rules were read back after convergence.
- External `curl --resolve` checks confirmed TLS, SNI routing, and application
  responses on the direct path.
- Public DNS was verified to return only `145.11.24.43` for the three public
  hostnames, with no AAAA records exposed.

## Notes for future changes

- If another service is made public, follow the same pattern:
  1. add RouterOS forwarding only for the intended port;
  2. verify the direct path externally;
  3. cut over Cloudflare DNS only after the direct path is proven;
  4. keep rollback via the VPS until the new path has been observed.
- Do not widen router management exposure to WAN.
- Keep per-site secrets separated in SOPS files.

