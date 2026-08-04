# mikrotik-bottega-base-lockdown

Implementation record for `specs/sites/bottega.md` phase 1:
**Base management lockdown** for a freshly installed MikroTik hAP be3 Media.

Run from `ansible/`:

```bash
ansible-playbook playbooks/bottega-base-lockdown.yml
```

## Scope

This role implements Bottega phase 1 and preserves the phase 2 WAN boundary on
reruns after PPPoE exists:

- RouterOS management services limited to the declared management subnets.
- RouterOS HTTPS listeners disabled until the later public-exposure phase.
- WAN/LAN interface-list baseline.
- Existing phase 2 PPPoE WAN interfaces kept in `WAN`, not `LAN`.
- The complete input firewall chain: four base rules plus any declared WAN
  exceptions.
- LAN-scoped MAC recovery.
- Admin SSH key import and SSH password-auth disablement.
- Bottega-specific SOPS recovery password for WinBox/console recovery.

It intentionally does not configure PPPoE, VLANs, WireGuard, dst-nat, Wi-Fi,
service exposure, or topology/addressing changes. The PPPoE task still owns
creating and enabling `pppoe-out1`; this role only treats that interface as
WAN when it already exists.

## Input-Chain Ownership Contract

This role owns the **whole** `input` chain, not just its own four rules. Later
phases that need a WAN exception declare it here instead of adding a rule
behind this role's back:

```yaml
bottega_mikrotik_input_exceptions:
  - comment: "Bottega phase 5 input 03a accept-wireguard"
    protocol: udp
    dst_port: 61536
    in_interface_list: WAN
```

`comment` must be unique; `protocol` and `dst_port` are required;
`in_interface_list` defaults to `WAN`; `src_address` and `dst_address` are
optional. Declarations are checked into
`ansible/inventory/group_vars/mikrotik.yml` so every playbook that touches this
router agrees on the same chain.

The reason this is not optional: `tasks/firewall.yml` rebuilds the chain with
`/ip firewall filter remove [find where chain=input]` whenever the readback
drifts. A rule added outside this model would be silently deleted on the next
run of the base lockdown — dropping a live WireGuard tunnel, which is the
remote-lockout scenario `AGENTS.md` #4 exists to prevent. Exceptions are always
emitted between `accept !WAN` and `drop WAN`, so the WAN drop stays last.

`tasks/read-input-firewall-state.yml` is included by other phase roles
(`bottega_phase4`, `bottega_phase5`) to assert the chain is intact before and
after their own changes; it exports `_bottega_input_firewall_ok`.

Similarly, `bottega_mikrotik_management_subnets` is the full list of subnets
allowed to reach `www`/`ssh`/`winbox`. Validation asserts an exact match, so an
unexpected entry fails rather than silently widening management access.

## Spec Link

Source of truth: `specs/sites/bottega.md#base-management-lockdown`.

The spec defines the target state; this role records the RouterOS/Ansible
mechanics needed to make that state repeatable.

## Bootstrap Flow

The playbook supports three router states:

- Fresh factory router: falls back to the blank `admin` password.
- Partially bootstrapped router: uses the SOPS recovery password.
- Locked-down router: uses the imported admin SSH key.

The role sets a strong `admin` recovery password from
`ansible/secrets/bottega.sops.yml`, imports the local ed25519 public key for
`admin`, verifies key login, then disables SSH password authentication.

The recovery password remains necessary for WinBox and console recovery; it is
not used for routine SSH access after lockdown.

## RouterOS Notes

Observed on the Bottega hAP be3 Media RouterOS 7 build:

- Disabled `/ip service` rows print with a leading `X`, not `disabled=yes`.
- `/tool mac-server print terse`, `/tool mac-server mac-winbox print terse`,
  and `/ip neighbor discovery-settings print terse` are rejected; use plain
  `print`.
- MAC access readback is formatted as `allowed-interface-list: LAN` and
  `discover-interface-list: LAN`.
- This build exposes SSH password control as
  `/ip ssh set password-authentication=no`; older docs/spec language may refer
  to `always-allow-password-login=no`, so validation accepts either readback.
- `ansible.netcommon.net_put` can leave the persistent `network_cli` session in
  a bad state; the role resets the connection after uploading the SSH public
  key before importing it.

## Validation

Local checks used during implementation:

```bash
yamllint playbooks/bottega-base-lockdown.yml roles/mikrotik-bottega-base-lockdown
ansible-playbook --syntax-check playbooks/bottega-base-lockdown.yml
ansible-lint playbooks/bottega-base-lockdown.yml
```

Router validation is built into `tasks/validate.yml` and checks:

- `www`, `ssh`, and `winbox` are limited to exactly
  `bottega_mikrotik_management_subnets`.
- `telnet`, `ftp`, `api`, `api-ssl`, and `www-ssl` are disabled.
- If RouterOS exposes `reverse-proxy`, it is disabled.
- Input firewall has exactly the base rules plus the declared exceptions, in
  spec order, with `drop in-interface-list=WAN` last.
- `WAN` contains `ether1`, `LAN` contains `bridge`, with no overlap.
- If `pppoe-out1` exists, it is a member of `WAN` and not `LAN`.
- MAC server, MAC WinBox, and neighbor discovery are LAN-scoped.
- Admin SSH key exists and SSH password auth is disabled.
- SSH port `22` and WinBox port `8291` are reachable from the internal
  management host.

Verified live:

- First successful run completed with `failed=0`.
- Follow-up idempotence run completed with `changed=0`, `failed=0`.
- Manual SSH key login works.
- Manual WinBox access works.
- WAN does not expose the router admin panel.

## Phase-Gated Checks

Still outside phase 1:

- External WAN scan after PPPoE bring-up.
- WireGuard UDP `61536` exposure after the WireGuard phase.
- TCP `443` exposure after the dst-nat/public-exposure phase.
- MAC WinBox recovery from a directly cabled no-IP laptop, when physically
  convenient.
