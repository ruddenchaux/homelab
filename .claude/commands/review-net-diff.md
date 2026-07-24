---
description: Review a diff touching network config for lockout risk, subnet overlap, and WireGuard AllowedIPs asymmetry.
---

# /review-net-diff

Review the given diff (or the current working-tree diff if none is specified)
against these checks, in order:

1. **Lockout risk**: does the diff touch a firewall `input`/`forward` chain,
   routing table, or a WireGuard peer that a remote site or the reviewer's own
   current session depends on to reach the router? Flag anything that could
   apply without a way back in (no safe-mode, no scheduled revert) — see
   `.claude/skills/mikrotik-safe-change.md`.
2. **Subnet overlap**: does the diff introduce or change an IP range? Check it
   against every subnet listed in `specs/network/topology.md` (Bottega's VLANs,
   Casa's LAN, the site-to-site tunnel subnet, the road-warrior pool). Flag any
   overlap. Flag if `specs/network/topology.md` wasn't updated in the same diff
   when addressing changed (`AGENTS.md` rule #2).
3. **AllowedIPs asymmetry**: for any WireGuard peer change, confirm both ends
   of the peer relationship changed together, and that
   `specs/network/wireguard.md`'s table was updated in the same diff
   (`AGENTS.md` rule #3). Flag if only one side changed, or if the table wasn't
   touched.
4. **Router management exposure**: flag any rule that binds or allows a
   management service (WinBox/WebFig/API/SSH) on a WAN-facing interface, at
   either site (`AGENTS.md` rule #5).
5. **Secrets**: flag any plaintext secret, or any secret added to a shared
   (non-per-site) SOPS file that should be site-scoped (`AGENTS.md` rule #1).

Report findings ordered by severity (lockout risk first), each with the
specific file/line and which rule or spec section it violates.
