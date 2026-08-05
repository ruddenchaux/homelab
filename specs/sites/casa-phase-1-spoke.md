# Casa Phase 1: WireGuard Spoke + LAN Renumber

## Summary

- **Site**: Casa
- **Phase**: 1 — Casa's first spec-driven change; the "Casa side" deferred by
  `specs/sites/bottega-phase-5-wireguard.md` §"Why Casa is a separate phase".
- **Goal**: convert the Casa MikroTik (L009) from the obsolete single-site lab
  router into the thin Casa spoke — renumber its LAN off the Bottega-overlapping
  `192.168.88.0/24`, tear down the now-empty lab VLANs and the VPS relay tunnel,
  and dial out to the Bottega hub so the two sites can reach each other.
- **Primary specs**: `specs/sites/casa.md`, `specs/network/topology.md`,
  `specs/network/wireguard.md`, `specs/network/firewall.md`.
- **Implementation**: `ansible/roles/casa_spoke`,
  `ansible/roles/bottega_casa_peer`, `ansible/playbooks/casa-spoke.yml`, plus the
  inventory restructure (see "Implementation").

This is the mirror of Bottega Phase 5 on the spoke side. After it, the
site-to-site tunnel described in `topology.md` is complete and the VPS relay is
gone from the Casa end.

## Context — confirmed state (2026-08-04)

Confirmed with the repo owner while planning this change:

- The lab (R740xd / Proxmox / k8s) has **physically moved to Bottega**. The
  Bottega hub is **live** with Phase 5 applied: `wg-hub` on UDP `61536` at the
  static public IP **`145.11.24.43`** (the spec value is real, not a placeholder).
- The MikroTik **L009UiGS-2HaxD stays at Casa as the spoke**.
- Owner decisions folded into this spec:
  - **Casa's WireGuard key is RouterOS-generated** and never leaves the router;
    Casa has **no** SOPS file and **no** age recipient. Only its *public* key is
    read back (non-secret) for the hub peer. See `wireguard.md` §"Key custody".
  - **The VPS relay tunnel is removed at the Casa end in this change** — the
    owner chose this over `MIGRATION.md`'s "keep as rollback" default, because
    the relay's target (the lab) has left Casa and it now serves nothing.
  - **AdGuardHome stays at Casa** as local DNS (it is a RouterOS container on the
    `containers` bridge, `10.10.20.2`), on its own `10.10.20.0/24` which does not
    overlap any Bottega subnet.

## Current state as found on the Casa router (read-only audit)

Read from `192.168.88.1` (identity `MikroTik`, RouterOS 7.22.1, serial
`HK20AZ5Z8CB`). Preflight for the implementation should re-read these and refuse
to proceed on unexpected drift.

### WAN — confirms the Starlink/CGNAT (Casa) side
- `ether1`: DHCP client, `100.112.252.225/10`, default route via `100.64.0.1`
  (CGNAT, the forbidden `100.64.0.0/10` range). `/ip cloud` public-address
  `216.128.11.90` (shared egress, not inbound-routable). **No inbound WAN config
  exists or should exist** — Casa only dials out.

### Addresses
| Address | Interface | Disposition |
|---|---|---|
| `192.168.88.1/24` (defconf) | `bridge` | **Renumber → `192.168.90.1/24`** |
| `10.10.50.1/24` (INVALID) | `*10` | **Remove** (guest-wifi cruft) |
| `10.10.20.1/24` | `containers` | **Keep** (AdGuard container net) |
| `10.10.0.1/24` | `vlan10-management` | **Remove** (lab moved) |
| `10.20.0.1/24` | `vlan20-trusted-lan` | **Remove** (lab moved) |
| `10.30.0.1/24` | `vlan30-kubernetes` | **Remove** (lab moved) |
| `10.100.0.2/30` | `wg-vps` | **Remove** (VPS teardown) |

### WireGuard (current)
- `wg-vps`: mtu 1420, listen-port 51820, pubkey `OTS5WOpz…`. Peer `peer1` →
  `89.167.62.126:51820`, allowed `10.100.0.1/32`, keepalive 25s, **live**
  (handshake ~34s, rx 9.3 MiB / tx 12 MiB). **Remove entirely.**
- No `wg-hub`/`wg-casa`. Only `wg-vps` exists.

### Interface lists
- `LAN` = `bridge`, `vlan10-management`, `vlan20-trusted-lan`, `vlan30-kubernetes`.
- `WAN` = `ether1`.

### Firewall — filter (forward tail, beyond defconf)
- `dhcp_guest_bridge:forward`: drop `src 10.10.50.0/24 → dst 192.168.88.0/24` — **remove**.
- `fw-wg-vps-fwd`: accept `in wg-vps → out vlan30-kubernetes` — **remove**.
- `fw-wg-bridge-fwd`: accept `in wg-vps → out bridge` — **remove**.
- defconf input chain (accept est/rel/untracked; drop invalid; accept icmp;
  accept dst `127.0.0.1`; **drop `in-interface-list=!LAN`**) — keep. Because the
  final input rule drops everything not from `LAN`, adding `wg-casa` to the `LAN`
  list is what makes Bottega-over-tunnel "LAN-equivalent" for router management
  (`firewall.md` Casa table), with no new input rule needed.

### Firewall — NAT
- `defconf masquerade` out `WAN` — keep.
- `dhcp_guest_bridge:masquerade` src `10.10.50.0/24` — **remove**.
- masquerade src `10.10.20.0/24` — **keep** (AdGuard container egress).
- dstnat `192.168.88.1:80 → 10.10.20.2:80` (AdGuard web UI) — **update dst to
  `192.168.90.1`**.

### DHCP / DNS
- Server `defconf` on `bridge`, pool `default-dhcp` `192.168.88.10-254`, lease 30m.
- Networks: guest `10.10.50.0/24` (**remove**); defconf `192.168.88.0/24` gw
  `192.168.88.1` dns `10.10.20.2` (**renumber → `192.168.90.0/24` gw
  `192.168.90.1`, keep dns `10.10.20.2`**).
- `/ip dns`: dynamic-servers from Starlink, `allow-remote-requests=yes`.
- Note (out of router scope): AdGuard has a wildcard rewrite
  `*.ruddenchaux.xyz → 10.30.0.200`. That target now lives at Bottega and is
  reachable over the tunnel (Casa AllowedIPs include `10.30.0.0/24`), so Casa
  clients keep resolving lab hostnames. Verify after cutover.

### Bridge / VLAN
- `bridge`: `vlan-filtering=yes`, pvid 1. Bridge-VLAN table: id 1 untagged
  bridge; ids 10/20/30 tagged on `bridge` only (**remove the 10/20/30 entries**);
  dynamic pvid entry for `ether2`/`wifi1` on vlan 1.
- All physical ports (`ether2-8`, `sfp1`, `wifi1`) are pvid-1 access ports — **no
  trunk carries 10/20/30 to any port** (the Proxmox trunk left with the lab),
  confirming the VLANs are safe to delete.
- `vlan10-management`, `vlan20-trusted-lan`, `vlan30-kubernetes` on `bridge` —
  **remove all three interfaces**.

> **Audit correction (found while implementing).** The bridge-VLAN entries for
> 10/20/30 read `tagged=ether6,bridge`, not `bridge` alone — the old Proxmox
> trunk *configuration* is still there. The conclusion is unchanged, because
> `current-tagged` is `bridge` only on all three: `ether6` is link-down, so no
> port is actually carrying those VLANs. The implementation checks
> `current-tagged`/`current-untagged` rather than the configured `tagged` list
> for exactly this reason, and refuses if a live physical port appears.
>
> Consequence: `ether6` is also set `frame-types=admit-only-vlan-tagged`.
> Deleting VLANs 10/20/30 leaves it a port that silently drops every frame it
> receives, so the change **returns `ether6` to `frame-types=admit-all`**,
> matching `ether2-ether8`/`sfp1`.

### Container
- `adguardhome` on `veth1` (→ `containers` bridge), root
  `/usb1-part1/volumes/adguardhome`. **Keep untouched.**

### Scripts / schedulers
- Two **disabled** schedulers (`EnableGuestWifi`, `DisableGuestWifi`) and their
  two scripts, both acting on a `wifi2` interface that no longer exists. More
  guest-wifi cruft, but inert — **out of scope**, listed here so the
  implementation's "no unexpected script/scheduler" preflight has a known
  baseline. Remove in a follow-up if desired.

### `/ip service` — hardening gaps found
Every service on this router is enabled, and every one has `address=""` (no
source restriction; only the input `drop !LAN` protects them). Bottega, by
contrast, was locked down in phase 2: `www`/`ssh`/`winbox` address-restricted,
`telnet`/`ftp`/`api`/`api-ssl`/`www-ssl` disabled and `reverse-proxy` disabled
where present (`mikrotik-bottega-base-lockdown`). The two sites are the same
hardware running the same RouterOS, so the spoke is brought to the hub's
posture rather than a weaker one of its own:

- **Disable** `ftp` (21), `telnet` (23), `api` (8728), `api-ssl` (8729),
  `www-ssl` (443) and `reverse-proxy` (443). `www-ssl` and `reverse-proxy` are
  the widest gap found — two unrestricted admin listeners on 443. `api`/`api-ssl`
  are disabled rather than restricted because nothing in this repo speaks the
  RouterOS API; Ansible drives both routers over SSH.
- **Restrict** `www` (8080 on this router, not 80), `ssh` and `winbox` to
  `192.168.90.0/24,10.99.0.0/24` — the Casa-side equivalent of Bottega's
  management-subnet grant, so router admin is reachable from the flat LAN and
  from Bottega over the tunnel, never from WAN (`AGENTS.md` #5).

## Target state — the change set

### Casa router (applied on-site by the operator)

**Remove (obsolete):**
- `wg-vps` interface + its address + `peer1`, and the `fw-wg-vps-fwd` /
  `fw-wg-bridge-fwd` forward rules. (The dynamic `/ip service wireguard-wg-vps`
  disappears with the interface.)
- VLANs 10/20/30: the three `vlanNN-*` interfaces, their three addresses, their
  three bridge-VLAN entries, and their `LAN` interface-list memberships.
- Guest cruft: the invalid `10.10.50.1/24` address (and its `*10` interface if
  orphaned), the `10.10.50.0/24` dhcp-network, the guest masquerade, and the
  guest forward-drop.

**Renumber (LAN `192.168.88.0/24 → 192.168.90.0/24`):**
- `bridge` address → `192.168.90.1/24`.
- pool `default-dhcp` → `192.168.90.10-192.168.90.254`.
- dhcp-network → `192.168.90.0/24`, gw `192.168.90.1`, dns `10.10.20.2`.
- AdGuard web dstnat dst-address → `192.168.90.1`.

**Add (`wg-casa` spoke → Bottega hub):**
- Interface `wg-casa`, `mtu=1412`, RouterOS-generated key (read back only the
  public key). Add to the `LAN` interface list (never `WAN`).
- Address `10.99.0.2/32` on `wg-casa`.
- Peer → Bottega: `public-key=<Bottega wg-hub public key>`,
  `endpoint-address=145.11.24.43`, `endpoint-port=61536`,
  `persistent-keepalive=25`,
  `allowed-address=10.99.0.0/24,10.10.0.0/24,10.20.0.0/24,10.30.0.0/24`
  (mirror of `wireguard.md` AllowedIPs table).
- MSS clamp: `chain=forward action=change-mss new-mss=clamp-to-pmtu
  passthrough=yes protocol=tcp tcp-flags=syn out-interface=wg-casa`.
- Static routes via `wg-casa` for each AllowedIPs subnet that has no connected
  route (the `/32` interface address leaves none): `10.99.0.0/24`,
  `10.10.0.0/24`, `10.20.0.0/24`, `10.30.0.0/24`. RouterOS did **not** derive the
  overlay route from `allowed-address` on the Bottega hAP build (Phase 5 "Facts
  Confirmed"); verify on this L009 build and own the routes rather than assume.

**Harden:**
- Disable `ftp`, `telnet`, `api`, `api-ssl`, `www-ssl` and `reverse-proxy`.
- Restrict `www`/`ssh`/`winbox` to `192.168.90.0/24,10.99.0.0/24`.

**Keep unchanged:** the AdGuard container and its `containers` bridge /
`10.10.20.0/24` / masquerade; the WAN dhcp-client and default masquerade; the
defconf input chain.

### Bottega hub side (additive; applied over the road-warrior tunnel)

Follows the Phase 5 per-peer pattern — Casa and the road-warrior share `wg-hub`,
so every Casa rule must match on `src-address=10.99.0.2`, never interface alone.

- Peer on `wg-hub`: `public-key=<Casa wg-casa public key>`,
  `allowed-address=10.99.0.2/32,192.168.90.0/24`, **no** endpoint, **no** keepalive.
- Static routes via `wg-hub` for **both** `10.99.0.2/32` and `192.168.90.0/24`
  (same reason as the Phase 5 road-warrior route: the hub address is a `/32`, so
  nothing is connected, and RouterOS does not derive routes from a peer's
  `allowed-address` on this build). *Revised while implementing — an earlier
  draft of this section listed only the `/32`. Without the `192.168.90.0/24`
  route the lab → Casa accept rule below matches traffic the hub then has
  nowhere to send, and the "Home Assistant at Bottega reaches devices at Casa"
  criterion fails.*
- Address list `casa-networks` = `10.99.0.2/32`, `192.168.90.0/24`.
- Forward accept: `in-interface=wg-hub src-address-list=casa-networks
  dst-address-list=bottega-lab-vlans` (Casa → lab), placed before the first
  enabled forward drop. *Revised while implementing — an earlier draft scoped
  this on `src-address=10.99.0.2` alone, which matches only the Casa router's
  own overlay address. Traffic from Casa LAN hosts is sourced from
  `192.168.90.x` and would not match, failing `topology.md`'s "a host on Casa's
  LAN can reach a host on Bottega's VLAN 30" in the Casa-initiated direction.
  The address list keeps the rule scoped per-peer (interface **and** source),
  which is the property that matters, while covering everything behind Casa.*
- Forward accept: lab → Casa, `src-address-list=bottega-lab-vlans
  dst-address=192.168.90.0/24 out-interface=wg-hub` (Home Assistant → Casa
  devices use case; return traffic rides established/related).
- Forward accept, road-warrior → Casa: `in-interface=wg-hub
  src-address=10.99.0.11 dst-address=192.168.90.0/24` — the phone profile's
  AllowedIPs already include `192.168.90.0/24`; without this hub rule that route
  is inert. *Marked optional in an earlier draft; included, so the already-issued
  phone profile works without being reissued.* Note this rule can only be
  exercised **from the phone**, not from the dev-box: the dev-box shares the
  `10.99.0.11` peer identity but must not carry `192.168.90.0/24` in its own
  `AllowedIPs` while it sits on Casa's LAN (`wireguard.md`).
- The `wg-hub` MSS clamp from Phase 5 already covers tunnel egress — do not add a
  second one.
- **No input/base-lockdown change**: the `61536` listener from Phase 5 already
  accepts Casa. Do not touch `bottega_mikrotik_input_exceptions`.

## Implementation

- **Role `ansible/roles/casa_spoke`** — mirrors the `bottega_phase5`
  preflight/converge/validate idiom (strict read-back of owned objects; create
  only when absent; refuse on drift). It owns the `wg-casa` build, the teardown,
  the hardening and the renumber. The old `mikrotik-wireguard` role
  (VPS-relay-shaped, no read-back) is untouched.
  - Two entry points, because the hub-side peer has to be applied between them:
    `tasks_from: tunnel` (preflight + build `wg-casa` + read its public key) and
    `tasks_from: site` (handshake gate + teardown + cutover). `main.yml` runs
    both plus `validate`.
  - Objects are owned by a `casa-phase1-*` comment and read back property by
    property. The audit in this document is **never** trusted at run time —
    `read-audit.yml` re-reads every value it depends on.
- **Role `ansible/roles/bottega_casa_peer`** — the hub side. A separate role
  rather than an extension of `bottega_phase5`, so the guardrail is structural:
  it never includes `mikrotik-bottega-base-lockdown`, and its `validate` asserts
  the input-chain rule count is unchanged.
- **Playbook `ansible/playbooks/casa-spoke.yml`** — four plays, in the Safe
  Application order: read the hub's public key (Bottega, read-only) → build
  `wg-casa` with it (Casa) → add the Casa peer with Casa's public key (Bottega)
  → handshake gate, teardown, cutover (Casa). Keys cross between plays through
  `hostvars`, the old `vps-relay.yml` shape. Neither key is secret, so nothing
  new goes into SOPS.
- **Inventory** — a parent `routers` group holds the shared RouterOS connection
  vars (`group_vars/routers.yml`), with `mikrotik` (Bottega) and `casa` as
  children; Bottega playbooks keep `hosts: mikrotik`. Casa inherits **no**
  `bottega_mikrotik_*` variable. `mikrotik-gw` is retargeted from
  `192.168.88.1` — which now resolves to *this Casa router* — to `10.99.0.1`
  over the road-warrior tunnel. Casa's `ansible_host` is
  `{{ casa_router_address }}`, defaulting to the post-renumber `192.168.90.1`;
  the cutover run passes `-e casa_router_address=192.168.88.1`. The override is
  scoped to that variable rather than to `ansible_host` precisely because the
  playbook also targets Bottega.

### How steps 5–6 are applied

The renumber destroys the transport the change travels over, and the `/ip
service` restriction to `192.168.90.0/24,10.99.0.0/24` must not land while the
router still answers only on `192.168.88.1`. The two therefore have to be atomic
*from the operator's point of view*, which means running with no operator session
attached at all.

`converge-cutover.yml` writes both steps into one RouterOS script
(`casa-phase1-cutover`), **reads the stored source back and asserts it matches
byte for byte**, and only then arms a one-shot scheduler a few seconds out.
Ansible returns cleanly; the session drops afterwards, on purpose. The script
removes its own scheduler as its last statement so it cannot re-fire after a
reboot, and every statement matches on the value it replaces, so re-running it is
a no-op rather than a second renumber (verified: RouterOS `set` on an empty
`find` is a no-op, not an error).

This is the scheduler-based backstop `.claude/skills/mikrotik-safe-change.md`
recommends for remote-site changes, used here for the session-drop rather than
for auto-revert — the operator is physically on site, which the spec makes the
primary backstop, and a surprise auto-revert mid-verification would be worse than
none.

### Split run — the two sites driven from different machines

The four plays assume one control machine that can reach both routers, carrying
each router's public key to the other through `hostvars`. When Bottega's
credentials live on a different machine than the one at Casa (which is the case
today — see Prerequisites), `--limit` runs each site's plays where they can
actually connect and the two public keys are passed by hand with `-e`.

This costs nothing in safety and adds no secret handling: **both values are
public keys**. Each play prints the one the other side needs, and both roles'
preflights refuse with an explicit message when the key is absent, before
touching anything. The exact sequence is in the `casa-spoke.yml` header.

The ordering constraint is unchanged and is what makes the split safe: the Casa
machine's first run stops at the teardown gate, because `wg-casa` cannot have
handshaked until the hub has been given Casa's peer. That refusal is the design,
not a failure.

### RouterOS gotchas this implementation had to handle

All of these fail *silently* rather than loudly — as wrong data, not as an
error — which is why every one of them was caught by a strict read-back rather
than by the command that caused it. The first two were found by dry-running the
read-only path; the rest surfaced during the live apply, each one stopping the
run at a gate with the router in a safe state.

**Matching:**

- **`find where` needs quoted string values.** `out-interface-list=WAN` matches
  **zero** rules; `out-interface-list="WAN"` matches the defconf masquerade.
  Every string value in a `find where` is quoted.
- **…and that includes enum-valued matchers.** `protocol=udp and dst-port=61536`
  matched zero rules on a chain that demonstrably contained the rule;
  `protocol="udp" and dst-port="61536"` matched it. Verified empirically that
  `chain=`, `action=` and `vlan-ids=` are *not* affected — they return identical
  counts quoted or not — so the rule is "quote everything", not "quote the ones
  that are known to break".
- **A YAML fold must never split a `key=value`.** A folded
  `list=\n{{ var }}` renders as `list= WAN`, which RouterOS parsed as a match on
  *every* rule in the table rather than as an error. Keep `key=value` pairs on
  one line.

**Reading values back** — the whole of this group is why the roles never parse
`print terse` and never take "the last line" of a command's output:

- **The console hard-wraps output at 80 columns, mid-value, with no continuation
  marker.** Output lines are indistinguishable from genuine ones, so
  `stdout_lines | map('last')` silently yields a fragment
  (`.0/24;allowed-address=10.30.0.0/24`) whenever a value is long. Every read is
  built to emit short lines — one per list entry, or fixed-width chunks for the
  cutover script — and parsing filters to lines matching `^[a-z][a-z0-9-]*=`,
  which rejects echoed commands (`:`/`<` prefixed) and wrap tails alike.
- **`:put` of a list property repeats the key and joins with `;`.** It is not the
  comma-separated string `print` displays: `allowed-address=10.99.0.0/24;allowed-address=10.10.0.0/24…`,
  and `/ip service` addresses read back as `192.168.90.0/24;10.99.0.0/24`.
  Anything comparing a list read this way must normalise the separator or read
  one entry per line.
- **`/ip firewall address-list` normalises `/32` away.** `add address=10.99.0.2/32`
  reads back as `10.99.0.2`. Routes are *not* normalised — they keep the `/32` —
  so only the address-list comparison strips it. Left unhandled this breaks
  idempotency, not just validation: every subsequent run reports the entry
  missing and tries to add it again.

## AGENTS.md rules and how this satisfies them

- **#1 secrets / per-site separation** — Casa's key is RouterOS-generated; no
  Casa private key is stored anywhere, so there is no new SOPS file or age
  recipient. Bottega stores only Casa's *public* key (non-secret).
- **#2 no subnet overlap + update `topology.md` same change** — the renumber to
  `192.168.90.0/24` removes the overlap with Bottega VLAN 1, and the removal of
  the stale VLANs 10/20/30 is what lets Casa route those subnets to Bottega over
  the tunnel (otherwise a local same-numbered interface shadows the tunnel route,
  violating the topology "no subnet on both routing tables" criterion).
  `topology.md` already carries `192.168.90.0/24`; no value is invented.
- **#3 WireGuard both-ends + peer table same change** — Casa's `wg-casa` peer,
  the Bottega `wg-hub` Casa peer, and the `wireguard.md` peer-matrix status all
  land together.
- **#4 MikroTik idempotent + safe-mode** — role uses preflight/converge/validate
  and `*_confirmed` gates; the renumber runs with the operator **physically at
  Casa** as the backstop for the session drop (see Safe Application).
- **#5 mgmt never on WAN** — Casa exposes nothing inbound from WAN (CGNAT); the
  `/ip service` restriction keeps admin on `192.168.90.0/24,10.99.0.0/24` only.
  The Bottega side adds no WAN input rule.

## Safe Application

Follow `.claude/skills/mikrotik-safe-change.md`. The operator is on the Casa LAN
(e.g. `192.168.88.254` over Wi-Fi) with **physical/console access** as the
backstop.

**The order matters because the LAN renumber drops the operator's own session.**
Everything except the renumber is done first over the current `192.168.88.x`
link; `wg-casa` is independent of the renumber and comes up while still on `.88`:

1. Build `wg-casa` (interface → address → LAN membership → peer → routes → MSS
   clamp). Confirm handshake to Bottega (`/interface wireguard peers print`).
2. Apply the Bottega hub-side Casa peer (over the road-warrior tunnel) and
   confirm the handshake from the hub side too.
3. Remove `wg-vps` (peer → forward rules → address → interface).
4. Remove VLANs 10/20/30 (LAN memberships → addresses → interfaces →
   bridge-VLAN entries) and the guest cruft.
5. Harden `/ip service`. The **disables** cannot lock out this change's own
   operator — Ansible drives the router over `ssh`, and `winbox` stays up as the
   fallback — so they are applied immediately, in step 4. Anyone administering
   Casa through Webfig-over-HTTPS (`www-ssl`, 443) does lose that path and must
   use `www` on 8080 or Winbox instead. The **address restriction** must not land
   while the router still answers only on `.88`, so it is deferred into step 6.
6. **Renumber last**: bridge address, pool, dhcp-network, AdGuard dstnat, plus
   the `/ip service` address restriction — one atomic RouterOS script fired by a
   one-shot scheduler (see "How steps 5–6 are applied"). The operator's link
   drops → renew DHCP → reconnect on `192.168.90.x`.
7. Re-run the playbook to converge (`changed=0`) and run `validate`.

## Prerequisites

- [ ] Bottega hub is live and reachable to apply its side — the operator's
      dev-box can WireGuard into Bottega via the Phase 5 road-warrior profile,
      and that profile's AllowedIPs include `10.99.0.1/32` (or `10.99.0.0/24`) so
      Ansible can reach the Bottega router at its overlay address. Add the overlay
      to the client profile if missing (client-side-only change).
      **Status (2026-08-05)**: ✅ met. The tunnel is up (local interface
      `marconi`, `10.99.0.11/32`) and `10.99.0.0/24` has been added to its
      `AllowedIPs`, so Bottega answers on `10.99.0.1`. Note the profile carries
      only the overlay plus the three lab VLANs, deliberately **not**
      `192.168.90.0/24` — see `wireguard.md`, the dev-box is on Casa's LAN and a
      route for its own prefix via the tunnel would fight the connected route.
- [ ] A control machine that can authenticate to the router it is driving.
      **Status (2026-08-05)**: ✅ met. The dev-box's `id_ed25519` has been
      imported on Bottega and is accepted by both routers, so a **single-machine
      run** is possible and is the recommended path. (Until 2026-08-04 the key
      was rejected by Bottega and that box held no `age1rxyz…` recipient for
      `ansible/secrets/bottega.sops.yml` — `AGENTS.md` #1's per-site
      blast-radius separation working as designed. The "Split run" section below
      remains the fallback if the two sites are ever driven from different
      machines again.)
- [ ] Operator is physically at Casa with console/cable access (the renumber
      backstop).
- [ ] A current `/export hide-sensitive` of the Casa router is stored off-router.
- [ ] RouterOS interactive safe mode ready on the Casa session.

## Rollback

Under safe mode, reverse order (policy/renumber before the tunnel it protects):

1. Renumber the LAN back to `192.168.88.0/24` (address, pool, dhcp-network,
   dstnat) and reconnect on `.88`.
2. Remove `wg-casa` (peer → routes → MSS clamp → address → interface) and its LAN
   membership.
3. Remove the Bottega hub-side Casa peer, route, and forward rules.
4. (Only if the VLANs/VPS teardown must be undone — normally not needed, the lab
   is gone) restore from the saved `/export`.

The Bottega road-warrior path and the Bottega hub itself are untouched by a Casa
rollback, so remote access to Bottega never depends on this change.

## Acceptance Criteria

**Applied 2026-08-05** in a single-machine run from the dev-box, which reached
Casa on its LAN and Bottega over the road-warrior tunnel. Every Casa-router and
Bottega-hub box below is verified; the cross-site connectivity boxes are left
open because they need a second host at each end to exercise, and the
road-warrior→Casa one specifically needs the phone (the dev-box must not carry
Casa's LAN in its AllowedIPs — see `wireguard.md`).

Casa router (from a host on `192.168.90.0/24` after cutover):
- [x] `/interface wireguard print` shows exactly one `wg-casa`, `mtu=1412`, with
      a peer to `145.11.24.43:61536` and `persistent-keepalive=25`.
- [x] `/interface wireguard peers print` shows a recent handshake and non-zero
      rx/tx to Bottega.
- [x] `wg-vps` and its peer/forward rules are gone; `/interface wireguard print`
      shows no `wg-vps`.
- [x] No `vlan10/20/30` interfaces, addresses, or bridge-VLAN entries remain; no
      `10.10.50.x` guest address/rules remain.
- [x] `ip addr`/`ip route` show no subnet present on both Casa and Bottega
      routing tables except the deliberate tunnel subnet (`topology.md`).
- [x] `/ip service` shows `ftp`/`telnet`/`api`/`api-ssl`/`www-ssl`/`reverse-proxy`
      disabled and `www`/`ssh`/`winbox` limited to
      `192.168.90.0/24,10.99.0.0/24` — the same posture Bottega runs.
- [x] A second run of `casa-spoke.yml` reports `changed=0` and passes validate.

Tunnel / cross-site (live connectivity, not rule inspection):
- [ ] A host on Casa's LAN can reach a host on Bottega's VLAN 30, and the reverse
      succeeds (`topology.md`, `firewall.md`).
- [ ] A Casa LAN device (e.g. the EmonBase / MQTT broker once present) is
      reachable from Home Assistant running at Bottega (`casa.md`).
- [ ] An admin at Bottega can apply a RouterOS change to the Casa router over the
      tunnel, without physical access to Casa (`casa.md`).
- [ ] After a Casa router reboot the tunnel re-establishes automatically
      (dial-out + keepalive), no manual step (`casa.md`).
- [ ] `wg show` on Bottega's hub shows a recent handshake for the Casa peer, and
      removing the (now-gone) VPS peer had no effect on it (`wireguard.md`).

## Out of scope (follow-up changes)

- Full VPS decommission: the Hetzner host still runs `wg0`/nginx and the
  `jellyfin.ruddenchaux.xyz → 89.167.62.126` A record. Removing `wg-vps` at Casa
  only kills the Casa end of the tunnel. Retire the VPS host, the road-warrior
  VPS profile, and repoint public DNS to Bottega per `MIGRATION.md` and
  `specs/network/dns-exposure.md` separately.
- Confirming/adjusting AdGuard's `*.ruddenchaux.xyz` rewrite and Casa's static
  reachability inventory (`casa.md` `TODO(fact):` — EmonTx4/EmonBase, MQTT).
