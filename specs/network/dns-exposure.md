# DNS and exposure intent

## Current model

- Internal services resolve via split DNS to Traefik's internal IP on Bottega,
  `10.30.0.200`.
- If AdGuardHome is present on a LAN, it can provide that split DNS. When it
  is not present, RouterOS static DNS on the Bottega MikroTik serves the same
  purpose for LAN clients that use the router as their resolver.
- Public services that should be reachable from the raw internet get a real
  Cloudflare `A` record pointing at Bottega's static public IPv4 and a RouterOS
  `dst-nat` rule forwarding TCP `443` to Traefik.

## Target model (Bottega static IP, hub-and-spoke)

- **Split DNS stays**: internal clients on any site resolve
  `*.ruddenchaux.xyz` to Traefik's internal LB IP at Bottega. The resolver may
  be AdGuardHome or RouterOS static DNS depending on what is installed on the
  local LAN.
- **Public exposure**: any service that should be reachable from the raw
  internet gets a Cloudflare `A` record pointing directly at Bottega's static
  public IP, and a `dst-nat` (port forward) rule on Bottega's MikroTik
  forwarding TCP `443` to Traefik's internal LB IP.
- The "any service becomes public just by adding an A record" property from the
  VPS design is preserved, but the target is now Bottega's own IP + a `dst-nat`
  rule instead of the VPS + nginx.

## Public exposure policy

A public A record requires an explicit stated reason. Default is
internal-only, resolved via split DNS and reachable only over the VPN
(`specs/network/wireguard.md`). Adding a service to raw-internet exposure is a
deliberate opt-in, not automatic.

Public services (enumerated, extend explicitly as needed):

- `jellyfin.ruddenchaux.xyz` — streaming client compatibility requires direct
  internet reachability.
- `ha.ruddenchaux.xyz` — Home Assistant mobile/web access from outside the
  LAN.
- `immich.ruddenchaux.xyz` — photo sync/client access from outside the LAN.

## TLS handling

TLS-blind `dst-nat` passthrough: Bottega's router forwards TCP `443` untouched
to the k3s ingress LB (Traefik). TLS terminates at the ingress via cert-manager
— never on RouterOS.

## IP stability and monitoring

Bottega's public IP is contractually static: `145.11.24.43`. No DDNS is used —
RouterOS `/ip cloud` is explicitly **not** enabled, since with a confirmed
static IP it has no DNS-failover role to play.

The concern of "is the IP still reachable" is monitoring, not DNS, and belongs
outside this spec — tracked as `TODO(fact):` in
`specs/observability/external-checks.md` (external health check against the
public `443` endpoint and the WireGuard UDP listener). Public A records keep a
low TTL regardless, as cheap insurance against a future IP change.

## Acceptance criteria

- [ ] For every service with a public A record, `dig <hostname>` resolves to
      Bottega's static public IP.
- [ ] A request to a publicly-exposed hostname from outside any homelab VPN
      reaches Traefik and gets a valid Let's Encrypt certificate end-to-end.
- [ ] A request to any hostname *without* a public A record fails to resolve
      from outside the VPN.
- [ ] Only the enumerated public services above resolve to Bottega's static IP
      from outside the VPN; every other hostname resolves internal-only.
- [ ] Internal LAN clients resolve `*.ruddenchaux.xyz` to `10.30.0.200`
      through split DNS.
