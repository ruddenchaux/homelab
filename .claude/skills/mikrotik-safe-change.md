---
name: mikrotik-safe-change
description: Safe procedure for applying a risky change to a MikroTik router, especially at a remote site (Casa from Bottega, or vice versa), without risking lockout.
---

# Safe MikroTik change procedure

Applies to firewall, routing, and WireGuard-peer changes on either router.
Ground rule: `AGENTS.md` #4 — idempotent, safe-mode-minded, because a bad rule
on a remotely-managed router can lock you out until someone visits physically.

## Before the change

- [ ] Is this router reachable only remotely (e.g. Casa's MikroTik, changed
      from Bottega, or vice versa)? If yes, treat this as high-risk by default.
- [ ] Does the change touch firewall `input`/`forward` chains, routing, or a
      WireGuard peer that the current session depends on? If yes, high-risk.
- [ ] Confirm `community.routeros` + `ansible.netcommon` are usable
      (`ansible_connection: ansible.netcommon.network_cli`,
      `ansible_network_os: community.routeros.routeros`) and `paramiko` is
      installed — see `CLAUDE.md` "Important Notes" for the Fedora Kinoite
      `~/.local/lib` ownership gotcha if the collection fails to connect.

## Applying the change

1. **Idempotent tasks only**: use RouterOS module states that check-then-apply
   (Ansible `community.routeros` tasks, not raw one-shot scripts) so re-running
   the playbook after a partial failure doesn't duplicate or break rules.
2. **Safe-mode for interactive/manual changes**: when making the change by hand
   (WinBox/terminal) instead of via Ansible, use RouterOS's built-in safe mode
   (`Ctrl+X` in terminal, or the WinBox Safe Mode toggle) — it auto-reverts all
   changes if the session drops before you confirm, which is exactly the
   lockout scenario this guards against.
3. **For remote-site changes specifically**: prefer a scheduler-based
   auto-revert as a backstop even when using Ansible/safe-mode — e.g. a
   RouterOS scheduled task that reverts to a saved config export after N
   minutes unless cancelled, so a change that silently breaks the tunnel (and
   therefore your ability to cancel the revert) still self-heals.
4. Apply the change, then **verify from the vantage point that matters**: if
   the change affects the tunnel used to reach a remote site, verify
   connectivity to that site immediately, not just local convenience.
5. Update `specs/network/wireguard.md` and/or `specs/network/firewall.md` in
   the same change if the peer table or firewall intent changed (rules #2/#3).

## After the change

- [ ] Confirm the router is still reachable the way it was before (same
      management path — LAN/VPN, never WAN, per rule #5).
- [ ] Confirm the specific thing you changed behaves as intended (new peer
      handshakes, new firewall rule allows/blocks as expected).
- [ ] If this was a remote-site change, confirm you can still reach that site
      *without* relying on the change you just made (i.e. you didn't
      accidentally make your own access path dependent on the untested rule).

## Grounded in

`ansible/roles/mikrotik-vlans`, `ansible/roles/mikrotik-wireguard`, and
`ansible/roles/mikrotik-guest-cleanup` are the existing idempotent-task
examples in this repo. `TROUBLESHOOTING.md`'s client-VPN sections show what a
partially-applied MikroTik/UFW change looks like when diagnosed after the
fact — the goal of this procedure is to not need that diagnosis.
