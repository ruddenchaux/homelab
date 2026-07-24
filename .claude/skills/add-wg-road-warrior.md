---
name: add-wg-road-warrior
description: Add a new road-warrior WireGuard peer (phone/laptop) end to end, so it can administer or reach services at Bottega and Casa.
---

# Add a road-warrior WireGuard peer

## Before you start

- [ ] Confirm the peer's client name and the tunnel IP it should get (must not
      collide with an existing peer — check `specs/network/wireguard.md`).
- [ ] Confirm which subnets this device should reach (Bottega only, or
      Bottega + Casa) — this drives its `AllowedIPs` (client-side) and the
      hub's `AllowedIPs` for this peer.

## Steps (target architecture — Bottega is the hub)

1. Generate a WireGuard keypair for the client (idempotent — reuse if it
   already exists for this client name).
2. On Bottega's MikroTik (the hub, since it has the static IP and terminates
   WireGuard): add a peer entry for this client —
   `AllowedIPs = <client tunnel IP>/32`.
3. Ensure Bottega's forwarding rules allow traffic from this peer's interface
   to the subnets it's entitled to (per `specs/network/firewall.md`) — mirror
   the old `fw-wg-vps-fwd` pattern from `PUBLIC_INTERNET.md`, but the peer
   terminates directly on Bottega now, not on a VPS.
4. If this peer needs to also reach **Casa's** LAN through Bottega, confirm
   Bottega has a forwarding rule from this peer's AllowedIPs onward to the
   Casa tunnel interface, and that Casa's side allows it in
   (`specs/network/firewall.md`, Casa section).
5. Build the client config: `Endpoint = <Bottega static IP>:<wg port>`,
   `AllowedIPs = <subnets this client should reach>`, `PersistentKeepalive`
   only needed if the *client* is behind CGNAT (mobile data usually is — keep
   it).
6. Update `specs/network/wireguard.md`'s AllowedIPs table with this peer's row
   on **both** ends — required by `AGENTS.md` rule #3, in the same change.
7. Generate a QR code for mobile import (`qrencode`), same UX as today.
8. Verify: `wg show` on Bottega shows a handshake after the client connects;
   the client can reach every subnet declared in its `AllowedIPs`, and nothing
   else.

## What changes vs. the current (VPS-relay) procedure

Today's version of this task is `ansible/roles/vps-client-vpn` — the peer
terminates on the **Hetzner VPS**, which masquerades traffic before it reaches
MikroTik. Under the new architecture, the peer terminates **directly on
Bottega's MikroTik** — no VPS, no masquerade hop, no `10.100.0.0/24` VPS-tunnel
subnet. The masquerade concept doesn't disappear, but it moves: if the
road-warrior needs to reach a subnet Bottega itself doesn't own routes for
(e.g. Casa's LAN, reached only via the site-to-site tunnel), the equivalent
NAT/forwarding logic is needed on Bottega's router for the Bottega→Casa hop,
not on a relay VPS.

## Key files (today, being superseded)

- `ansible/roles/vps-client-vpn/` — keypair, peer, QR code generation logic to
  adapt for the new hub.
- `ansible/roles/mikrotik-wireguard/` — MikroTik-side interface/peer/firewall
  tasks to generalize for "MikroTik acting as hub" instead of "MikroTik dialing
  a VPS".
