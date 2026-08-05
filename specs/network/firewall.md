# Firewall intent per site

Per `AGENTS.md` rules #4 and #5: MikroTik changes must be idempotent and
safe-mode-aware, and router management interfaces must never be exposed to WAN.

## Bottega (hub)

> **Phasing**: the tables below are the **end state**, and Bottega has now
> reached it. The router started from the base lockdown in
> `specs/sites/bottega.md`, where WAN answered nothing at all; Phase 3 added
> only local VLANs; TCP `443` opened with the Phase 4 dst-nat task
> (`sites/bottega-phase-4-public-https.md`), and UDP `61536` with the Phase 5
> WireGuard task (`sites/bottega-phase-5-wireguard.md`). A port scan showing
> nothing open through Phase 3 was the *correct* result at the time — see the
> phase table in `sites/bottega.md`.

Input (traffic destined for the router itself):

| Source | Destination port/service | Allow? | Notes |
|--------|---------------------------|--------|-------|
| WAN | WireGuard UDP `61536` | Yes | Only open inbound WAN VPN service — this is the point of being the hub. Port from `specs/network/wireguard.md` |
| WAN | TCP `443` | Yes | dst-nat to the k3s ingress LB (Traefik). See `specs/network/dns-exposure.md` |
| WAN | TCP `80` | **No** | Not needed — certificates use ACME DNS-01 via Cloudflare, no inbound HTTP-01 challenge required |
| WAN | Router management (WinBox/WebFig/API/SSH) | **No** | Rule #5 — management only from LAN/VPN |
| WAN | anything else | **No** | Default-deny from WAN. Exactly two exceptions exist: WireGuard `61536` and TCP `443` — nothing else is ever opened directly |
| LAN / VPN | Router management | Yes | Firewall acceptance is not sufficient on its own: `/ip service` binds `www`/`ssh`/`winbox` to an address list, so the WireGuard overlay `10.99.0.0/24` has to be in that list too. Phase 5 adds it |

Note on chains: only WireGuard `61536` is a true **input**-chain exception — it
terminates on the router. TCP `443` is dst-nat'd in prerouting to Traefik and
is therefore evaluated in the **forward** chain, needing a forward-accept rule,
not an input-accept rule. The table groups them for readability; the
implementation must not.

Forward (traffic passing through the router):

| From | To | Allow? | Notes |
|------|----|--------|-------|
| WireGuard (Casa peer) | Bottega lab VLANs it's entitled to (per `wireguard.md` AllowedIPs) | Yes | `casa-phase1-fwd-casa-to-lab`: `in-interface=wg-hub`, `src-address-list=casa-networks`, `dst-address-list=bottega-lab-vlans`. Lands on the same `wg-hub` interface as the road-warrior, so it is scoped by source as well as interface — never by interface alone. The source is an **address list** (`10.99.0.2/32` + `192.168.90.0/24`), not the Casa router's `/32` alone: hosts behind Casa are sourced from `192.168.90.x` and would otherwise not match. See `sites/casa-phase-1-spoke.md` |
| WireGuard (road-warrior peer) | Bottega lab VLANs | Yes | Implemented as `bottega-phase5-fwd-roadwarrior`: `in-interface=wg-hub`, `src-address=10.99.0.11`, `dst-address-list=bottega-lab-vlans` |
| WireGuard (road-warrior peer) | onward to Casa's LAN | Yes | `casa-phase1-fwd-roadwarrior-to-casa`: `in-interface=wg-hub`, `src-address=10.99.0.11`, `dst-address=192.168.90.0/24`. Without it the `192.168.90.0/24` entry in the phone profile's AllowedIPs is a route to nowhere |
| Bottega lab VLANs | WireGuard (toward Casa) | Yes, for the subnets Casa should be reachable/reachable-from | `casa-phase1-fwd-lab-to-casa`: `src-address-list=bottega-lab-vlans`, `dst-address=192.168.90.0/24`, `out-interface=wg-hub`. Needed for the Home Assistant → Casa devices use case; return traffic rides established/related |
| Any other cross-VLAN traffic | — | Follow existing VLAN segmentation intent (mgmt/trusted/k8s isolated), unchanged from single-site design | See `NETWORKING.md` for the current rule set being carried forward |

## Casa (spoke)

| Source | Destination | Allow? | Notes |
|--------|-------------|--------|-------|
| WAN | anything (Casa has no static IP / no inbound WAN rule needed) | N/A | CGNAT means there is nothing to configure inbound-from-WAN at Casa — it only dials out |
| WireGuard (from Bottega, once tunnel is up) | Casa router management | Yes, treated as "LAN-equivalent" per rule #5, never as a WAN exposure | Required per `sites/casa.md` acceptance criteria: an admin at Bottega must be able to apply a RouterOS change to Casa's router over the tunnel without physical access. Reachable because Bottega's `AllowedIPs` for the Casa peer includes Casa's LAN `192.168.90.0/24` (see `wireguard.md`), which is where the router's management interface lives |
| WireGuard (from Bottega) | Casa LAN devices | Yes | Required use case: Home Assistant (at Bottega) reaching local devices at Casa |
| Casa LAN | WireGuard (toward Bottega) | Yes | Required: Casa must be administrable from Bottega |

Casa needs **no new forward rule** for any of the above. Its defconf forward
chain ends at "drop all from WAN not DSTNATed", scoped to the `WAN` interface
list; `wg-casa` is a `LAN`-list member, so tunnel traffic in both directions
falls through to the chain's default accept. Likewise, no new *input* rule: the
defconf input chain's last rule drops everything whose in-interface is not in
`LAN`, so adding `wg-casa` to `LAN` is the entire mechanism that makes Bottega
"LAN-equivalent" for Casa router management.

Firewall acceptance is not sufficient on its own at Casa either: `/ip service`
binds `www`/`ssh`/`winbox` to `192.168.90.0/24,10.99.0.0/24`, and
`ftp`/`telnet`/`api`/`api-ssl`/`www-ssl`/`reverse-proxy` are disabled outright —
the same posture Bottega runs, so the spoke never exposes a broader admin
surface than the hub. Neither subnet is reachable from Casa's WAN, which is
CGNAT and carries no inbound configuration at all.

## Acceptance criteria

- [ ] Neither router's management service (WinBox/WebFig/API/SSH) answers on
      its WAN-facing interface — verified by a connection attempt from outside
      the LAN/VPN (e.g. `nmap` from a host that is not on LAN/VPN).
- [ ] Bottega's only WAN-inbound accepted services are TCP `443` and
      WireGuard UDP `61536` — an external port scan against Bottega's static
      IP shows
      nothing else answering, notably not TCP `80`.
- [ ] Traffic from Casa's WireGuard peer can reach exactly the Bottega subnets
      listed in its `AllowedIPs` row in `wireguard.md`, and nothing else.
- [ ] A host at Casa is reachable from a host on Bottega's lab VLAN (Home
      Assistant use case), confirmed with a live connectivity test (e.g. ping
      or an app-level check), not just a rule inspection.
