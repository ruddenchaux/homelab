# Bottega Phase 2 Lockdown

## Summary

- **Site**: Bottega
- **Phase**: 2, PPPoE / WAN bring-up after base management lockdown
- **Goal**: WAN is up, but nothing on the router answers from WAN.
- **Primary spec**: `specs/sites/bottega.md`
- **Implementation**: `ansible/playbooks/bottega-base-lockdown.yml`

## Context

Phase 1 locks down a factory hAP be3 on the default LAN. Phase 2 brings up
PPPoE on the static public IP, but it must not expose router management or any
other router-local service.

The important RouterOS detail is that decapsulated PPPoE traffic arrives on the
PPPoE interface, not on the physical WAN port. Both `ether1` and `pppoe-out1`
must therefore be members of the `WAN` interface list. If `pppoe-out1` is
missing from `WAN`, the base input rule `accept in-interface-list=!WAN` treats
public traffic as trusted.

## Required State

RouterOS services:

- `www`, `ssh`, and `winbox` are enabled only for `192.168.88.0/24`.
- `telnet`, `ftp`, `api`, `api-ssl`, and `www-ssl` are disabled.
- `reverse-proxy`, if present on this RouterOS build, is disabled.

Input chain:

1. `accept connection-state=established,related`
2. `drop connection-state=invalid`
3. `accept in-interface-list=!WAN`
4. `drop in-interface-list=WAN`

Those four rules are exact. They must be enabled, in that order, and must not
carry extra match fields such as `protocol`, `src-address`, `dst-address`, or
`dst-port`. The final `drop in-interface-list=WAN` remains last until a later
phase intentionally inserts a WAN exception before it.

Interface lists:

- `WAN` contains `ether1`.
- If `pppoe-out1` exists, `WAN` contains `pppoe-out1`.
- `LAN` contains `bridge`.
- No interface is in both `WAN` and `LAN`.

## Phase Order

Phase 1 and Phase 2 expose nothing on WAN.

Phase 3 is VLANs and the R740xd uplink:

- VLANs 10, 20, and 30 become available locally through a tagged `ether5`
  server trunk.
- WAN still answers nothing.
- See `specs/sites/bottega-phase-3-vlans.md`.

Phase 4 is dst-nat / public exposure:

- TCP `443` becomes reachable from WAN.
- This is a prerouting dst-nat plus forward-chain path to Traefik.
- It is not an input-chain exception and must not bind a RouterOS local HTTPS
  service.

Phase 5 is WireGuard:

- UDP `61536` becomes reachable from WAN.
- This is the only router-local WAN input exception.
- The accept rule is inserted before the final WAN drop.

## Implementation Guardrails

The Ansible role must not accept a visually similar but unsafe input chain.
Convergence and validation both check the same strict RouterOS readback:

- exactly four input rules
- `disabled=false` for all four rules
- exact comments, actions, connection states, and interface-list predicates
- empty `protocol`, `src-address`, `dst-address`, and `dst-port` where the spec
  does not require those fields

Local Claude permission files are not repo state. `.claude/settings.local.json`
must remain ignored and uncommitted.

## Acceptance Criteria

Internal, from `192.168.88.0/24`:

- [ ] `/ip service print` matches the service state above.
- [ ] `/ip firewall filter print chain=input` shows exactly the four-rule input
      chain above, enabled and in order.
- [ ] `/interface list member print` shows `ether1` and `pppoe-out1` in `WAN`,
      `bridge` in `LAN`, and no overlap.
- [ ] SSH and WinBox remain reachable from the LAN management host.

External, from outside the LAN/VPN:

- [ ] `nmap -Pn -p 22,80,443,8291 145.11.24.43` shows no open ports.
- [ ] `nmap -Pn -p 8728,8729 145.11.24.43` shows no open ports.

Phase-aware later checks:

- [ ] After Phase 3, TCP `443` and UDP `61536` remain closed/filtered.
- [ ] After Phase 4, only TCP `443` is open from WAN.
- [ ] After Phase 5, only TCP `443` and UDP `61536` are open from WAN.
