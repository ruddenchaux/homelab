# WireGuard peer matrix

Single source of truth for every WireGuard peer relationship. Per `AGENTS.md`
rule #3: any change to a peer must update **both ends** and this table in the
same change.

## Peers

| Peer A | Peer B | Who initiates | Purpose | Status |
|--------|--------|----------------|---------|--------|
| Bottega MikroTik (hub) | Casa MikroTik (spoke) | Casa dials out to Bottega (CGNAT) | Site-to-site: Casa LAN ↔ Bottega lab | **Not implemented** — needs Casa in inventory, its own age recipient, and the LAN renumber |
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
| Bottega ↔ road-warrior | Phone | `10.99.0.11/32` | `10.10.0.0/24`, `10.20.0.0/24`, `10.30.0.0/24`, `192.168.90.0/24` | `Endpoint=145.11.24.43:61536`, `PersistentKeepalive=25`, `DNS=10.30.0.1` |

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
Peer keypairs (the road-warrior's, and Casa's when it exists) live in
Bottega's SOPS file only — `AGENTS.md` #1.

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
