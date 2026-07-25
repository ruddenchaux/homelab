# Firewall intent per site

Per `AGENTS.md` rules #4 and #5: MikroTik changes must be idempotent and
safe-mode-aware, and router management interfaces must never be exposed to WAN.

## Bottega (hub)

Input (traffic destined for the router itself):

| Source | Destination port/service | Allow? | Notes |
|--------|---------------------------|--------|-------|
| WAN | WireGuard UDP `61536` | Yes | Only open inbound WAN VPN service — this is the point of being the hub. Port from `specs/network/wireguard.md` |
| WAN | TCP `443` | Yes | dst-nat to the k3s ingress LB (Traefik). See `specs/network/dns-exposure.md` |
| WAN | TCP `80` | **No** | Not needed — certificates use ACME DNS-01 via Cloudflare, no inbound HTTP-01 challenge required |
| WAN | Router management (WinBox/WebFig/API/SSH) | **No** | Rule #5 — management only from LAN/VPN |
| WAN | anything else | **No** | Default-deny from WAN. Exactly two exceptions exist: WireGuard `61536` and TCP `443` — nothing else is ever opened directly |
| LAN / VPN | Router management | Yes | |

Forward (traffic passing through the router):

| From | To | Allow? | Notes |
|------|----|--------|-------|
| WireGuard (Casa peer) | Bottega lab VLANs it's entitled to (per `wireguard.md` AllowedIPs) | Yes | Mirrors the old `fw-wg-vps-fwd` pattern, source interface changes from `wg-vps` to the Casa peer interface |
| WireGuard (road-warrior peer) | Bottega lab VLANs + (if in scope) onward to Casa | Yes | |
| Bottega lab VLANs | WireGuard (toward Casa) | Yes, for the subnets Casa should be reachable/reachable-from | Needed for Home Assistant → Casa devices use case |
| Any other cross-VLAN traffic | — | Follow existing VLAN segmentation intent (mgmt/trusted/k8s isolated), unchanged from single-site design | See `NETWORKING.md` for the current rule set being carried forward |

## Casa (spoke)

| Source | Destination | Allow? | Notes |
|--------|-------------|--------|-------|
| WAN | anything (Casa has no static IP / no inbound WAN rule needed) | N/A | CGNAT means there is nothing to configure inbound-from-WAN at Casa — it only dials out |
| WireGuard (from Bottega, once tunnel is up) | Casa router management | Yes, treated as "LAN-equivalent" per rule #5, never as a WAN exposure | Required per `sites/casa.md` acceptance criteria: an admin at Bottega must be able to apply a RouterOS change to Casa's router over the tunnel without physical access. Reachable because Bottega's `AllowedIPs` for the Casa peer includes Casa's LAN `192.168.90.0/24` (see `wireguard.md`), which is where the router's management interface lives |
| WireGuard (from Bottega) | Casa LAN devices | Yes | Required use case: Home Assistant (at Bottega) reaching local devices at Casa |
| Casa LAN | WireGuard (toward Bottega) | Yes | Required: Casa must be administrable from Bottega |

## Acceptance criteria

- [ ] Neither router's management service (WinBox/WebFig/API/SSH) answers on
      its WAN-facing interface — verified by a connection attempt from outside
      the LAN/VPN (e.g. `nmap` from a host that is not on LAN/VPN).
- [ ] Bottega's only WAN-inbound accepted services are WireGuard UDP `61536`
      and TCP `443` — an external port scan against Bottega's static IP shows
      nothing else answering, notably not TCP `80`.
- [ ] Traffic from Casa's WireGuard peer can reach exactly the Bottega subnets
      listed in its `AllowedIPs` row in `wireguard.md`, and nothing else.
- [ ] A host at Casa is reachable from a host on Bottega's lab VLAN (Home
      Assistant use case), confirmed with a live connectivity test (e.g. ping
      or an app-level check), not just a rule inspection.
