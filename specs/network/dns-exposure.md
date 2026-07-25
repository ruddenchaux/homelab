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

## Public exposure policy

A public A record requires an explicit stated reason. Default is
internal-only, resolved via split-DNS and reachable only over the VPN
(`specs/network/wireguard.md`). Adding a service to raw-internet exposure is a
deliberate opt-in, not automatic.

Public services (enumerated, extend explicitly as needed):

- `jellyfin.ruddenchaux.xyz` — streaming client compatibility requires direct
  internet reachability (existing reason, carried over from the VPS design).

## TLS handling

TLS-blind dst-nat passthrough: Bottega's router forwards TCP `443` untouched to
the k3s ingress LB (Traefik). TLS terminates at the ingress via cert-manager —
never on RouterOS. This keeps certificate issuance and routing decisions in the
GitOps layer instead of splitting them across the router, and matches the
existing TCP-passthrough approach used by the (now-retired) VPS relay.

## IP stability and monitoring

Bottega's public IP is contractually static: `145.11.24.43`. No DDNS is used —
RouterOS `/ip cloud` is explicitly **not** enabled, since with a confirmed
static IP it has no DNS-failover role to play, and being router-side it would
go silent exactly when the router (and therefore the thing it's meant to
detect failure of) is down.

The concern of "is the IP still reachable" is monitoring, not DNS, and belongs
outside this spec — tracked as `TODO(fact):` in
`specs/observability/external-checks.md` (external health check against the
public `443` endpoint and the WireGuard UDP listener). It is post-cutover and
non-blocking. Public A records keep a low TTL regardless, as cheap insurance
against a future IP change.

## Acceptance criteria

- [ ] For every service with a public A record, `dig <hostname>` resolves to
      Bottega's static public IP (not the retired VPS IP).
- [ ] A request to a publicly-exposed hostname from outside any homelab VPN
      reaches Traefik and gets a valid Let's Encrypt certificate end-to-end.
- [ ] A request to any hostname *without* a public A record fails to resolve
      from outside the VPN (split-DNS boundary holds).
- [ ] Only the enumerated public services above resolve to Bottega's static IP
      from outside the VPN; every other hostname resolves internal-only.
