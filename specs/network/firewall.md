# Firewall intent per site

Per `AGENTS.md` rules #4 and #5: MikroTik changes must be idempotent and
safe-mode-aware, and router management interfaces must never be exposed to WAN.

## Bottega (hub)

Input (traffic destined for the router itself):

| Source | Destination port/service | Allow? | Notes |
|--------|---------------------------|--------|-------|
| WAN | WireGuard port | Yes | Only open inbound WAN service — this is the point of being the hub |
| WAN | Router management (WinBox/WebFig/API/SSH) | **No** | Rule #5 — management only from LAN/VPN |
| LAN / VPN | Router management | Yes | |
| `TODO(decision):` | any other public-facing port (if a non-WireGuard service is ever exposed directly at Bottega instead of via k8s ingress) | `TODO(decision):` | Default should be no — service exposure goes through `dns-exposure.md` / dst-nat to Traefik, not a direct WAN rule |

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
| WireGuard (from Bottega, once tunnel is up) | Casa router management | **No**, unless explicitly needed for remote admin — if yes, treat as "LAN-equivalent" per rule #5, never as a WAN exposure | `TODO(decision):` whether Bottega admins reach Casa's router mgmt over the tunnel |
| WireGuard (from Bottega) | Casa LAN devices | Yes | Required use case: Home Assistant (at Bottega) reaching local devices at Casa |
| Casa LAN | WireGuard (toward Bottega) | Yes | Required: Casa must be administrable from Bottega |

## Acceptance criteria

- [ ] Neither router's management service (WinBox/WebFig/API/SSH) answers on
      its WAN-facing interface — verified by a connection attempt from outside
      the LAN/VPN (e.g. `nmap` from a host that is not on LAN/VPN).
- [ ] Bottega's only WAN-inbound accepted service is the WireGuard port.
- [ ] Traffic from Casa's WireGuard peer can reach exactly the Bottega subnets
      listed in its `AllowedIPs` row in `wireguard.md`, and nothing else.
- [ ] A host at Casa is reachable from a host on Bottega's lab VLAN (Home
      Assistant use case), confirmed with a live connectivity test (e.g. ping
      or an app-level check), not just a rule inspection.
