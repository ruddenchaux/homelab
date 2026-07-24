# DNS and exposure intent

## Current model (single-site, being replaced)

- Internal services resolve via AdGuardHome wildcard
  (`*.ruddenchaux.xyz → 10.30.0.200`, Traefik's Cilium L2 IP) — no public DNS
  record needed.
- The one publicly-exposed service (Jellyfin) has a real Cloudflare A record
  pointing at the Hetzner VPS IP, which relays via WireGuard to Traefik. See
  `PUBLIC_INTERNET.md` for the full mechanism and `MIGRATION.md` for why it's
  being decommissioned.

## Target model (Bottega static IP, hub-and-spoke)

- **Split-DNS stays**: internal clients (on any site, reachable over the
  WireGuard mesh) resolve `*.ruddenchaux.xyz` to Traefik's internal LB IP at
  Bottega, same as today — this doesn't change, only the router doing the
  resolving/forwarding might (Casa's own local DNS, if any, needs to forward to
  Bottega the way MikroTik currently forwards to AdGuardHome).
- **Public exposure changes**: any service that should be reachable from the
  raw internet (not just VPN clients) gets a Cloudflare A/AAAA record pointing
  directly at **Bottega's static public IP**, and a **dst-nat (port forward)**
  rule on Bottega's MikroTik forwarding the relevant port to Traefik's internal
  LB IP. This replaces the VPS nginx TCP-stream passthrough — Bottega's router
  does the equivalent job directly, since it now has a public IP to receive on.
- The "any service becomes public just by adding an A record" property from the
  VPS design is preserved, but the target is now Bottega's own IP + a dst-nat
  rule instead of the VPS + nginx.

## Open decisions

- `TODO(decision):` which services (if any beyond Jellyfin) get a public A
  record once Bottega is live — this is a decision, not automatic, since more
  surface = more to secure (rule #5 still applies: this is about *service*
  ports, router mgmt is never included).
- `TODO(decision):` whether Bottega's router does TLS-blind dst-nat (mirroring
  the VPS's SNI-blind nginx passthrough) or whether it should terminate/inspect
  anything at the router — recommend blind passthrough to keep Traefik as the
  single TLS termination point, matching the current design, but confirm.
- `TODO(decision):` DDNS or any monitoring needed in case Bottega's "static" IP
  is ever reassigned by the ISP (confirm with Flynet whether it's a fixed
  lease or truly static).

## Acceptance criteria

- [ ] For every service with a public A record, `dig <hostname>` resolves to
      Bottega's static public IP (not the retired VPS IP).
- [ ] A request to a publicly-exposed hostname from outside any homelab VPN
      reaches Traefik and gets a valid Let's Encrypt certificate end-to-end.
- [ ] A request to any hostname *without* a public A record fails to resolve
      from outside the VPN (split-DNS boundary holds).
- [ ] No `TODO(decision):` remains in this file before any dst-nat rule is
      applied to a live router.
