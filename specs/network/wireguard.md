# WireGuard peer matrix

Single source of truth for every WireGuard peer relationship. Per `AGENTS.md`
rule #3: any change to a peer must update **both ends** and this table in the
same change.

## Peers

| Peer A | Peer B | Who initiates | Purpose |
|--------|--------|----------------|---------|
| Bottega MikroTik (hub) | Casa MikroTik (spoke) | Casa dials out to Bottega (CGNAT) | Site-to-site: Casa LAN ↔ Bottega lab |
| Bottega MikroTik (hub) | Road-warrior (phone) | Phone dials out to Bottega | Remote admin + service access to both sites |

Retired once Bottega is verified (see `MIGRATION.md`):

| Peer A | Peer B | Status |
|--------|--------|--------|
| Hetzner VPS wg0 | Home MikroTik wg-vps | Superseded by Bottega hub — VPS relay tunnel decommissioned after cutover |

## AllowedIPs table

`TODO(decision):` fill in once addressing (`specs/network/topology.md`) is
finalized. Do not invent CIDRs here — this table must match `topology.md`
exactly once both are filled in.

| Interface | Endpoint side | Local address | AllowedIPs (what it accepts *from* the peer) | Notes |
|-----------|----------------|----------------|-----------------------------------------------|-------|
| Bottega ↔ Casa tunnel | Bottega (hub, listens) | `TODO(decision):` | `TODO(decision):` — must include Casa's LAN subnet | No `Endpoint=` on hub side (Casa initiates) |
| Bottega ↔ Casa tunnel | Casa (spoke, dials out) | `TODO(decision):` | `TODO(decision):` — must include Bottega's lab subnets it needs to reach | `Endpoint=<Bottega static IP>:<port>`, `PersistentKeepalive` only needed if Casa is behind CGNAT (it is) |
| Bottega ↔ road-warrior | Bottega (hub, listens) | `TODO(decision):` | `TODO(decision):` — single /32 for the phone | |
| Bottega ↔ road-warrior | Phone | `TODO(decision):` | `TODO(decision):` — must include both sites' reachable subnets if the phone needs Casa too | `Endpoint=<Bottega static IP>:<port>` |

## Design carried over from the VPS-relay tunnel (still applies)

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
