# Bottega Phase 4: Public HTTPS Exposure

## Summary

- **Site**: Bottega
- **Phase**: 4, direct public HTTPS forwarding and multi-host DNS cutover
- **Goal**: forward only raw internet TCP `443` from `WAN` to Traefik at
  `10.30.0.200:443`, validate it externally, then move
  `jellyfin.ruddenchaux.xyz`, `ha.ruddenchaux.xyz`, and
  `immich.ruddenchaux.xyz` from the VPS to Bottega's static IPv4.
- **Implementation**:
  `ansible/playbooks/bottega-phase-4-public-https.yml`

Phase 4 is deliberately a two-run cutover. The first run changes and validates
RouterOS but leaves production DNS on the VPS. The second run can change DNS
only when the same router state was already converged at the start of that run,
the inventory VPS has successfully tested the direct Bottega path, and the
operator passes `bottega_phase4_dns_cutover_confirmed=true`.

For a short operational record of what was actually done, see
[bottega-phase-4-public-https-notes.md](bottega-phase-4-public-https-notes.md).
That note is deliberately non-normative; this file stays the requirements and
rollback source of truth.

The VPS, its WireGuard tunnel, and its nginx relay remain available throughout
this phase as the rollback path.

## Scope and Non-Goals

Phase 4 creates exactly:

1. One enabled `forward` accept rule for dst-natted traffic arriving from
   `WAN` as TCP `443` and destined to `10.30.0.200:443`.
2. One enabled `dstnat` rule translating `WAN` TCP `443` to
   `10.30.0.200:443`.
3. One RouterOS split-DNS static A rule for `ruddenchaux.xyz` with
   `match-subdomain=yes`, so LAN clients resolve every `*.ruddenchaux.xyz`
   hostname to `10.30.0.200`.
4. DNS-only Cloudflare A record state for
   `jellyfin.ruddenchaux.xyz`, `ha.ruddenchaux.xyz`, and
   `immich.ruddenchaux.xyz`, all set to `145.11.24.43` with TTL 60.

This phase does not:

- add an input-chain exception;
- open TCP `80`;
- open UDP `61536` or add Phase 5 WireGuard state;
- add hairpin NAT;
- terminate TLS or enable HTTPS/reverse proxy on RouterOS;
- enable RouterOS `/ip cloud`;
- create an AAAA record;
- expose any hostname other than the three listed above;
- change VLANs, subnets, or unrelated firewall rules.

TLS stays end-to-end from the public client to Traefik. Traefik selects the
existing ingresses by SNI and terminates the existing cert-manager
certificates. Internal split DNS remains `*.ruddenchaux.xyz -> 10.30.0.200`.

## Prerequisites

Before the first run:

- [ ] Phase 3 is complete, including the exact VLAN 10/20/30 interfaces,
      gateways, LAN-only membership, tagged `ether5` trunk, and
      `bridge vlan-filtering=yes`.
- [ ] `pppoe-out1` is connected, belongs exactly once to `WAN`, and does not
      belong to `LAN`.
- [ ] Traefik and the Jellyfin, Home Assistant, and Immich ingresses answer
      internally at `10.30.0.200:443` with valid certificates.
- [ ] The existing VPS relay at `89.167.62.126` is healthy and its WireGuard
      path remains intact.
- [ ] An external scan records the closed baseline:
      TCP `22`, `80`, `443`, `8291`, `8728`, and `8729`, and UDP `61536`,
      are closed or filtered at `145.11.24.43`.
- [ ] A current `/export hide-sensitive` is stored off-router.
- [ ] RouterOS interactive safe mode or a tested timed rollback is ready.
- [ ] The operator can reach the router through LAN/MAC-WinBox if routed
      management fails.

The playbook makes the three external/recovery prerequisites explicit. It
will not mutate RouterOS unless these are all true:

```text
bottega_phase4_external_closed_baseline_confirmed=true
bottega_phase4_router_recovery_confirmed=true
bottega_phase4_vps_rollback_available_confirmed=true
```

Its read-only preflight then checks Phase 2, Phase 3, PPPoE link state,
Traefik HTTPS for every public hostname, the exact four-rule Phase 2 input
chain, disabled RouterOS `www-ssl`/reverse-proxy/IP proxy services, LAN/WAN
separation, TCP `443` rule conflicts, and split-DNS readiness.

## Cloudflare Credentials

Create a new Cloudflare API token limited to DNS edit for only the
`ruddenchaux.xyz` zone. Do not reuse the shared/VPS token. Store that token
and the zone ID only in the Bottega SOPS file:

```sh
cd ansible
sops set secrets/bottega.sops.yml \
  '["bottega_cloudflare_dns_api_token"]' '"ACTUAL_TOKEN"'
sops set secrets/bottega.sops.yml \
  '["bottega_cloudflare_zone_id"]' '"ACTUAL_ZONE_ID"'
```

The committed values are encrypted placeholders because credentials are not
part of repository source. The cutover play rejects those placeholders. The
`.sops.yaml` first-match rule encrypts this file only for Bottega's age
recipient; do not move either value to `ansible/secrets.sops.yml`.

## Required RouterOS State

Owned filter rule:

```text
chain=forward
action=accept
connection-nat-state=dstnat
in-interface-list=WAN
protocol=tcp
dst-address=10.30.0.200
dst-port=443
comment=bottega-phase4-https-forward
```

Owned NAT rule:

```text
chain=dstnat
action=dst-nat
in-interface-list=WAN
protocol=tcp
dst-port=443
to-addresses=10.30.0.200
to-ports=443
comment=bottega-phase4-https-dstnat
```

Owned split-DNS rule:

```text
name=ruddenchaux.xyz
type=A
address=10.30.0.200
ttl=1m
match-subdomain=yes
comment=bottega-phase4-split-dns
```

All are enabled and occur exactly once. The owned forward accept appears
before the first `forward` drop with `in-interface-list=WAN`, when such a drop
exists. The role moves only its owned accept rule and does not reorder or
rewrite unrelated rules.

The Phase 2 input chain remains byte-for-byte equivalent to its strict
four-rule readback. Router management continues to be LAN/VPN-only.

## Conflict Handling and Change Order

Before mutation, the role counts every direct `forward` or `dstnat` TCP
`dst-port=443` rule, the split-DNS comment, and both owned comments. It fails
if:

- an owned comment occurs more than once;
- a non-owned direct TCP `443` forward/NAT rule exists;
- the split-DNS comment occurs more than once;
- an owned rule has any drift in its enabled state, action, chain, interface
  scope, address, port, NAT-state restriction, or DNS match-subdomain state.

Resolve ambiguity manually under safe mode rather than allowing automation to
guess which internet-facing rule is intended.

Convergence order is:

1. Add the restricted forward accept.
2. Move that owned accept before the first applicable WAN forward drop.
3. Add dst-nat.
4. Enable RouterOS DNS remote requests if needed.
5. Add or normalize the split-DNS static record.
6. Strictly read back the owned rules, split-DNS state, the unchanged Phase 2
   input chain, disabled router HTTPS/proxy services, and LAN/WAN separation.

This ensures dst-nat is never installed before its restricted forward path.

## First Run: Router Path Only

Enter safe mode or arm the timed rollback, then run from `ansible/`:

```sh
ansible-playbook playbooks/bottega-phase-4-public-https.yml \
  -e bottega_phase4_external_closed_baseline_confirmed=true \
  -e bottega_phase4_router_recovery_confirmed=true \
  -e bottega_phase4_vps_rollback_available_confirmed=true
```

After RouterOS readback, the playbook logs into the inventory `vps` host and
runs the equivalent of:

```sh
curl --fail --resolve \
  jellyfin.ruddenchaux.xyz:443:145.11.24.43 \
  https://jellyfin.ruddenchaux.xyz/
curl --fail --resolve \
  ha.ruddenchaux.xyz:443:145.11.24.43 \
  https://ha.ruddenchaux.xyz/
curl --fail --resolve \
  immich.ruddenchaux.xyz:443:145.11.24.43 \
  https://immich.ruddenchaux.xyz/
```

The commands do not use `--insecure`: certificate validation, SNI selection,
and an application HTTP response from the direct Bottega path must all
succeed. Because they run on the VPS, the checks cannot accidentally pass
through LAN hairpin NAT. The DNS play then ends without loading Cloudflare
credentials or changing production DNS.

Before the second run, verify externally:

```sh
nmap -Pn -sT -p 22,80,443,8291,8728,8729 145.11.24.43
nmap -Pn -sU -p 61536 145.11.24.43
```

Only TCP `443` may be open. TCP `22`, `80`, `8291`, `8728`, `8729` and UDP
`61536` must remain closed or filtered.

## Second Run: DNS Cutover

After reviewing the successful direct-path and closed-port results, rerun:

```sh
ansible-playbook playbooks/bottega-phase-4-public-https.yml \
  -e bottega_phase4_external_closed_baseline_confirmed=true \
  -e bottega_phase4_router_recovery_confirmed=true \
  -e bottega_phase4_vps_rollback_available_confirmed=true \
  -e bottega_phase4_dns_cutover_confirmed=true
```

The router role must start already converged and report `changed=0`. The VPS
direct-path test runs again before any DNS API request. The DNS play then:

1. requires exactly one existing A record for each public hostname;
2. refuses to proceed if an AAAA record exists for any of them;
3. updates each existing A record to `145.11.24.43`, TTL 60, DNS-only;
4. performs strict Cloudflare API readback.

It never creates a missing A record, deletes an AAAA record, or touches another
hostname.

After the TTL has elapsed, check from outside the homelab/VPN:

```sh
dig +short A jellyfin.ruddenchaux.xyz
dig +short A ha.ruddenchaux.xyz
dig +short A immich.ruddenchaux.xyz
dig +short AAAA jellyfin.ruddenchaux.xyz
curl --fail https://jellyfin.ruddenchaux.xyz/
curl --fail https://ha.ruddenchaux.xyz/
curl --fail https://immich.ruddenchaux.xyz/
```

The A answers must be only `145.11.24.43`, the AAAA answer must be empty, and
HTTPS must present the valid Traefik/cert-manager certificates. From an
internal client, the same hostnames must still resolve to `10.30.0.200`.

## Rollback

Keep the VPS relay and tunnel running until Phase 4 has passed an extended
observation period. Roll back in this exact order:

1. Repoint the existing DNS-only Jellyfin, Home Assistant, and Immich A
   records to `89.167.62.126` with TTL 60.
2. Wait for public resolvers to return `89.167.62.126`, then verify normal
   HTTPS reaches the services through the VPS.
3. Under RouterOS safe mode, remove dst-nat first:

   ```routeros
   /ip firewall nat remove \
     [find where comment="bottega-phase4-https-dstnat"]
   ```

4. Remove the now-unused forward accept:

   ```routeros
   /ip firewall filter remove \
     [find where comment="bottega-phase4-https-forward"]
   ```

5. Repeat the Phase 3 external closed-port baseline and strict Phase 2
   input-chain/service checks.

Never remove the direct router rules before public DNS and HTTPS are proven
back on the VPS. Never remove the forward rule before dst-nat.

## Acceptance Criteria

Router:

- [ ] Exactly one enabled owned dst-nat translates `WAN` TCP `443` to
      `10.30.0.200:443`.
- [ ] Exactly one enabled owned forward accept is restricted by `WAN`, TCP
      `443`, destination `10.30.0.200`, and `connection-nat-state=dstnat`.
- [ ] The accept is before the applicable WAN forward drop.
- [ ] Exactly one enabled split-DNS static record matches
      `ruddenchaux.xyz` with `match-subdomain=yes`.
- [ ] The exact Phase 2 input chain, disabled RouterOS HTTPS/proxy services,
      and LAN/WAN separation pass strict readback.
- [ ] A second router convergence reports `changed=0`.

External:

- [ ] VPS `curl --resolve` validates TLS, SNI, and the application before DNS
      cutover for all three public hostnames.
- [ ] Only TCP `443` is open; TCP `22`, `80`, `8291`, `8728`, `8729`, and UDP
      `61536` remain closed or filtered.
- [ ] Public DNS returns only A `145.11.24.43` for Jellyfin, Home Assistant,
      and Immich; no AAAA exists.
- [ ] Normal external HTTPS reaches each service with a valid certificate.
- [ ] Internal split DNS still returns `10.30.0.200` for every
      `*.ruddenchaux.xyz` hostname.
- [ ] The documented rollback has been exercised while the VPS remains
      available, and service is proven through the VPS before direct rules are
      removed.
