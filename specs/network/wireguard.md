# WireGuard peer matrix

Single source of truth for every WireGuard peer relationship. Per `AGENTS.md`
rule #3: any change to a peer must update **both ends** and this table in the
same change.

## Peers

| Peer A | Peer B | Who initiates | Purpose | Status |
|--------|--------|----------------|---------|--------|
| Bottega MikroTik (hub) | Casa MikroTik (spoke) | Casa dials out to Bottega (CGNAT) | Site-to-site: Casa LAN ↔ Bottega lab | **Implemented** (2026-08-05) — `ansible/playbooks/casa-spoke.yml` (roles `casa_spoke` + `bottega_casa_peer`), see `specs/sites/casa-phase-1-spoke.md`. Hub peer `casa-phase1-hub-peer` and spoke peer `casa-phase1-peer-bottega` both report recent handshakes with non-zero rx/tx; both roles re-run `changed=0`. Casa is in inventory; **no** age recipient (Casa's key is RouterOS-generated, see "Key custody") |
| Bottega MikroTik (hub) | Road-warrior (phone) | Phone dials out to Bottega | Remote admin + service access to both sites | Implemented by `sites/bottega-phase-5-wireguard.md` |

Both peers terminate on the **same** hub interface `wg-hub`, since they share
one listener on UDP `61536`. `in-interface` therefore cannot distinguish them:
any firewall rule meant for one peer must also match on `src-address`.

Retired once Bottega is verified (see `MIGRATION.md`):

| Peer A | Peer B | Status |
|--------|--------|--------|
| Hetzner VPS wg0 | Home MikroTik wg-vps | Superseded by Bottega hub — VPS relay tunnel decommissioned after cutover |

## AllowedIPs table

Addressing values are taken from the single source of truth in
`specs/network/topology.md` — do not duplicate/re-derive CIDRs anywhere else.

### Derivation

- **Bottega's entry for Casa** must include Casa's LAN (`192.168.90.0/24`), so
  that Home Assistant running in the Bottega lab can reach devices at Casa by
  IP (EmonTx4/EmonBase, MQTT broker — see `sites/casa.md`). It also includes
  Casa's overlay `/32` so the tunnel itself has a route to Casa's WireGuard
  interface address.
- **Casa's entry for Bottega** must include the full overlay
  `10.99.0.0/24`, not just the hub's `10.99.0.1/32`. If it only had the hub's
  `/32`, Casa would have no route back to a road-warrior peer's overlay
  address (e.g. `10.99.0.11/32`) once traffic for it arrives via the hub —
  the phone could reach Bottega and, transitively, Casa, but Casa's replies to
  the phone would have no outbound route. It also includes Bottega's three lab
  VLANs (`10.10.0.0/24`, `10.20.0.0/24`, `10.30.0.0/24`), since Casa needs to
  reach services in the lab (DNS, admin, etc).
- **Bottega's entry for the road-warrior** is a single `/32`
  (`10.99.0.11/32`) — the phone has no LAN behind it, so nothing broader is
  needed or should be granted.
- **The phone's entry for Bottega** includes everything the phone is allowed
  to reach through the hub: Bottega's three lab VLANs and, since the phone
  also needs Casa, Casa's LAN (`192.168.90.0/24`) — reachable transitively
  through Bottega's forwarding rule (see `specs/network/firewall.md`).
- **The road-warrior's entry also includes the overlay `10.99.0.0/24`**, so the
  client has a route to the hub's *own* address `10.99.0.1`. Without it a
  road-warrior can reach everything behind Bottega but not Bottega's router,
  which is how Ansible administers the hub (the inventory targets `10.99.0.1`;
  `bottega_mikrotik_management_subnets` already grants `10.99.0.0/24`).
  This is a **client-side-only** change and not an AllowedIPs asymmetry: the
  hub's entry for this peer stays `10.99.0.11/32`, because that governs what the
  hub *accepts from* the client, and the client still only ever sources from
  `10.99.0.11`. What changed is what the client accepts *from the hub* — replies
  sourced from `10.99.0.1` — which only the client's own list can authorise.

mDNS/SSDP-based autodiscovery does **not** cross this tunnel — it's an L3
WireGuard link, and those protocols rely on L2 multicast/broadcast. Any Home
Assistant integration that depends on autodiscovery (e.g. some IoT devices)
must be configured with the target device's static IP instead of relying on
discovery.

| Interface | Endpoint side | Local address | AllowedIPs (what it accepts *from* the peer) | Notes |
|-----------|----------------|----------------|-----------------------------------------------|-------|
| Bottega ↔ Casa tunnel | Bottega (hub, listens) | `10.99.0.1/32` | `10.99.0.2/32`, `192.168.90.0/24` | No `Endpoint=` on hub side (Casa initiates); listens on UDP `61536` |
| Bottega ↔ Casa tunnel | Casa (spoke, dials out) | `10.99.0.2/32` | `10.99.0.0/24`, `10.10.0.0/24`, `10.20.0.0/24`, `10.30.0.0/24` | `Endpoint=145.11.24.43:61536`, `PersistentKeepalive=25` (Casa is behind CGNAT) |
| Bottega ↔ road-warrior | Bottega (hub, listens) | `10.99.0.1/32` | `10.99.0.11/32` | `wg-hub` peer `bottega-phase5-peer-roadwarrior`; no `Endpoint=` and no keepalive on hub side |
| Bottega ↔ road-warrior | Phone / dev-box | `10.99.0.11/32` | `10.99.0.0/24`, `10.10.0.0/24`, `10.20.0.0/24`, `10.30.0.0/24`, and `192.168.90.0/24` **only when the client is not itself on Casa's LAN** | `Endpoint=145.11.24.43:61536`, `PersistentKeepalive=25`, `DNS=10.30.0.1` |

The phone and the operator's dev-box currently share this one road-warrior peer
identity (`10.99.0.11`, one keypair, locally the `marconi` interface). That works
but is not ideal, for two reasons. First, WireGuard tracks a single endpoint per
peer, so the two devices cannot be connected at the same time — whichever
handshakes last wins.

Second, and the reason the last column above is conditional: the two devices do
not want the same `AllowedIPs`. The dev-box sits *on* Casa's LAN. Putting
`192.168.90.0/24` in its `AllowedIPs` would have wg-quick install a `/24` route
for that prefix via `marconi`, competing with the kernel's connected route for
the same prefix on the physical interface — the client would tunnel traffic
destined for machines on the wire next to it, or lose its own LAN outright.
`AllowedIPs` must therefore never contain a prefix the client is directly
attached to. The phone, which is remote, does want Casa's LAN and is the peer
the hub's `casa-phase1-fwd-roadwarrior-to-casa` rule exists to serve.

The dev-box's `marconi` profile consequently carries only `10.99.0.0/24` plus
Bottega's three lab VLANs, and that is correct rather than an omission — but it
means road-warrior→Casa reachability cannot be validated from the dev-box while
it is at Casa. Splitting the dev-box onto its own peer (`10.99.0.12`) with its
own profile is a small, additive follow-up on the hub that resolves both
problems; it is not a blocker for anything here.

The phone's `AllowedIPs` keeps Casa's LAN even though Casa is not yet a peer —
it is a route to nowhere until then, and including it now means the profile
does not have to be reissued when Casa comes up. Its `DNS` must point at a
Bottega gateway reachable inside the tunnel: without it the phone uses public
DNS, which resolves only the three publicly-exposed hostnames and leaves every
internal-only service unreachable.

## Design carried over from the VPS-relay tunnel (still applies)

- Interface MTU is `1412` on all WireGuard interfaces, with MSS clamping
  applied on the tunnel — see `specs/network/topology.md` "Tunnel parameters"
  for the reasoning (Bottega's PPPoE WAN + WireGuard overhead).
- `PersistentKeepalive` is required on whichever side sits behind CGNAT (Casa,
  and any mobile client), so the CGNAT mapping doesn't expire between packets.
  See `PUBLIC_INTERNET.md` "Lessons Learned" for the mechanism.
- Do not add `ip route add` in `PostUp` for a CIDR already covered by that
  peer's `AllowedIPs` — wg-quick creates the route automatically; duplicating
  it causes `RTNETLINK: File exists`. `PostUp`/`PreDown` is fine for
  iptables/nat rules that don't overlap with route management.
- If a peer (e.g. road-warrior) needs to reach a LAN through the hub that isn't
  its own directly-connected subnet, the hub needs a masquerade/forwarding rule
  analogous to the old VPS client-VPN design (`ansible/roles/vps-client-vpn`)
  — this replaces `iptables MASQUERADE` on the VPS with the equivalent on
  Bottega's MikroTik.

## Key custody

The hub's private key is generated by RouterOS on interface creation and never
leaves the router; only its public key is read back, to build client profiles.

The road-warrior peer's keypair is generated off-router and stored in Bottega's
SOPS file only — `AGENTS.md` #1 — because there is no RouterOS instance on the
phone to generate it in place.

Casa's key is different: Casa is a RouterOS router, so its `wg-casa` private key
is generated by the Casa MikroTik on interface creation and never leaves it,
exactly like the hub's. Only Casa's *public* key is read back, and it is not a
secret — it is carried as a plain inventory var for the hub-side peer config, so
Casa has **no** SOPS file and **no** age recipient of its own. This supersedes an
earlier draft of this section that said Casa's keypair lived in Bottega's SOPS
file; storing a second router's private key off-site would violate the per-site
blast-radius isolation `AGENTS.md` #1 requires.

## Acceptance criteria

- [ ] Every row above has no `TODO(decision):` before it is implemented.
- [ ] For every peer pair, the `AllowedIPs` on each side are the mirror image
      of what the other side actually owns (no over-broad grants, no missing
      subnets) — verified by comparing both configs against this table.
- [ ] `wg show` on Bottega's MikroTik shows a recent handshake for both the
      Casa and road-warrior peers.
- [ ] Casa's LAN is reachable from a host on Bottega's k8s VLAN (or vice versa,
      whichever direction the intended use case requires) over the tunnel.
- [ ] Removing the VPS peer entry does not affect the Casa or road-warrior
      peers (independent config blocks).
