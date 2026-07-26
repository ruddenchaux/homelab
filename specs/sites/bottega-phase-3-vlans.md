# Bottega Phase 3: VLANs and R740xd Uplink

## Summary

- **Site**: Bottega
- **Phase**: 3, VLAN provisioning and tagged server uplink
- **Goal**: make VLANs 10, 20, and 30 available through `ether5` without
  changing anything exposed on WAN.
- **Primary spec**: `specs/sites/bottega.md`
- **Implementation**:
  `ansible/playbooks/bottega-phase-3-vlans.yml`

Phase 3 is complete only when the router-side checks pass, the R740xd is
connected and powered on at the explicit checkpoint below, and the expected
Proxmox and Kubernetes addresses are reachable.

## Scope

`ether5` is a tagged-only trunk carrying:

| VLAN | Purpose | Router gateway |
|---|---|---|
| 10 | Management | `10.10.0.1/24` |
| 20 | Trusted LAN | `10.20.0.1/24` |
| 30 | Kubernetes | `10.30.0.1/24` |

The bridge CPU port and `ether5` are tagged members of all three VLANs.
VLAN 1 remains untagged on the bridge CPU port, `ether2`–`ether4`, and the
wireless interfaces already attached to the bridge. `ether5` is not an
untagged VLAN 1 member.

The existing Proxmox configuration does not change. Its VLAN-aware bridge is
already attached to BCM5720 `nic0`, and Proxmox management remains
`10.10.0.2` on tagged VLAN 10.

This phase does not add dst-nat, public DNS changes, WireGuard configuration,
DHCP or Wi-Fi redesign, subnets, or secrets. TCP `443` and UDP `61536` remain
closed/filtered from WAN; those are Phases 4 and 5.

## Prerequisites

Before running the playbook:

- [ ] Phase 2 is live: `pppoe-out1` exists and is a `WAN` member, `bridge` is
      a `LAN` member, and the lists do not overlap.
- [ ] SSH and WinBox work from `192.168.88.0/24`.
- [ ] An external scan confirms no tested service answers at
      `145.11.24.43`, including TCP `22`, `80`, `443`, `8291`, `8728`, and
      `8729`, plus UDP `61536`.
- [ ] `/interface ethernet print` confirms the literal server port is
      `ether5`.
- [ ] The management laptop is cabled directly through `ether2`, `ether3`, or
      `ether4`, never `ether5`.
- [ ] MAC-WinBox discovery and login have been tested from that laptop.
- [ ] The R740xd is powered off and disconnected from the router.
- [ ] A current RouterOS configuration export exists, and either an
      interactive safe-mode session or a tested timed rollback is ready.

The playbook requires explicit extra-variable confirmations for these physical
and external facts. Its RouterOS preflight then verifies the Phase 2 interface
lists, management reachability, bridge, trunk, and recovery ports before the
role mutates anything.

## Required RouterOS State

After convergence:

- `vlan10-management`, `vlan20-trusted-lan`, and `vlan30-kubernetes` exist on
  `bridge`.
- Their gateway addresses are exactly `10.10.0.1/24`, `10.20.0.1/24`, and
  `10.30.0.1/24`.
- All three VLAN interfaces belong to `LAN` and none belongs to `WAN`.
- No RouterOS interface belongs to both `LAN` and `WAN`.
- `ether5` is a bridge port with
  `frame-types=admit-only-vlan-tagged` and `ingress-filtering=yes`.
- Bridge VLAN rows 10, 20, and 30 are tagged exactly on `bridge` and `ether5`,
  with no untagged members.
- VLAN 1 is untagged exactly on `bridge`, every existing non-trunk bridge port
  (including `ether2`–`ether4` and existing wireless ports), and never
  `ether5`.
- `bridge vlan-filtering=yes` is set only after strict readback confirms the
  complete table and tagged-only trunk state.
- The Phase 2 firewall and WAN interface-list state remain unchanged.

## Safe Application

Follow `.claude/skills/mikrotik-safe-change.md`. Ansible does not itself turn
on interactive RouterOS safe mode, so the operator must provide the recovery
backstop before acknowledging the playbook guard.

From `ansible/`, run the playbook with the actual management port and every
confirmation set explicitly:

```sh
ansible-playbook playbooks/bottega-phase-3-vlans.yml \
  -e bottega_phase3_management_port=ether2 \
  -e bottega_phase3_mac_winbox_recovery_confirmed=true \
  -e bottega_phase3_rollback_confirmed=true \
  -e bottega_phase3_wan_closed_confirmed=true \
  -e bottega_phase3_server_off_and_disconnected_confirmed=true
```

The role orders changes to reduce lockout risk:

1. Validate the existing bridge, interface lists, trunk, recovery ports,
   gateway uniqueness, and VLAN-interface uniqueness.
2. Create or normalize the VLAN interfaces and gateways.
3. Put VLAN interfaces in `LAN` and remove any from `WAN`.
4. Set `ether5` tagged-only with ingress filtering.
5. Build and strictly read back the complete bridge VLAN table.
6. Enable bridge VLAN filtering.
7. Repeat strict readback of the table, interfaces, gateways, list membership,
   and LAN/WAN non-overlap.

Immediately verify `192.168.88.1` over SSH and WinBox from the same management
laptop. Run the playbook a second time with the same confirmations; the recap
must report `changed=0`.

## Rollback Requirements

If management access or any pre-power-on readback fails:

1. Do not connect or power on the R740xd.
2. Let the prepared safe-mode/timed rollback revert the change, or use
   MAC-WinBox from the directly attached management laptop.
3. Restore the saved export if the complete VLAN table cannot be corrected
   safely.
4. Confirm `192.168.88.1`, SSH, WinBox, MAC-WinBox, and the Phase 2 external
   closed-port scan before attempting Phase 3 again.

Do not remove VLAN rows piecemeal while relying on the affected bridge for
management. Treat VLAN filtering, the bridge table, and the `ether5` port
policy as one rollback unit.

## Router-Side Power-On Checkpoint

**The R740xd may be attached and powered on only after all of these checks
pass:**

- [ ] `/interface bridge vlan print` shows VLAN 1 untagged on the expected
      management ports and VLANs 10/20/30 tagged only on `bridge,ether5`.
- [ ] `/interface bridge port print where interface=ether5` shows tagged-only
      admission and ingress filtering.
- [ ] `/interface vlan print` and `/ip address print` show all three exact
      interfaces and gateways.
- [ ] `/interface list member print` shows the VLAN interfaces only in `LAN`
      and no LAN/WAN overlap.
- [ ] SSH and WinBox still reach `192.168.88.1`; MAC-WinBox recovery remains
      available.
- [ ] The external scan still shows router management, TCP `443`, and UDP
      `61536` closed/filtered.
- [ ] The second Ansible run reports `changed=0`.

## Physical Procedure

1. Keep the R740xd powered off and disconnected during the router change.
2. After the router-side checkpoint passes, connect BCM5720 `nic0`/port 3,
   which already carries the Proxmox trunk, to MikroTik `ether5`.
3. Power on the R740xd.
4. Confirm the link negotiates at 1 Gbps. Do not initially use the BCM57416
   10G ports; 2.5G fallback is unconfirmed.
5. Verify Proxmox, every Kubernetes node, Traefik, cluster health, and internal
   service resolution as listed below.

## Acceptance Criteria

Router and management:

- [ ] `ether5` is a tagged-only, ingress-filtered VLAN 10/20/30 trunk.
- [ ] VLAN gateways are `10.10.0.1`, `10.20.0.1`, and `10.30.0.1`.
- [ ] VLAN interfaces are in `LAN`, never `WAN`, with no list overlap.
- [ ] Untagged management works through `ether2`–`ether4`.
- [ ] SSH, WinBox, and MAC-WinBox recovery remain available from LAN.
- [ ] Router management remains unreachable from WAN.
- [ ] TCP `443` and UDP `61536` remain closed/filtered externally.
- [ ] A second playbook run reports `changed=0`.

Server and cluster, after the power-on checkpoint:

- [ ] The BCM5720 link reports 1 Gbps.
- [ ] Proxmox answers at `10.10.0.2`.
- [ ] Kubernetes nodes answer at `10.30.0.10`–`10.30.0.14`.
- [ ] Traefik answers on `10.30.0.200:443`.
- [ ] The Kubernetes cluster reports healthy nodes and workloads.
- [ ] A representative internal service resolves and answers through the
      expected internal DNS/Traefik path.
