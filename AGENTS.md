# Agent Rules

Always-on, non-negotiable rules for any agent or human working in this repo.
Everything else — architecture decisions, procedures, and reference — lives in
`specs/`, `.claude/skills/`, and the topic `*.md` files. This file stays short.

## 1. Secrets: SOPS + age only, per-site separation

Never commit plaintext secrets. All secrets go through SOPS + age
(`.sops.yaml`, `*.sops.yml`). With two sites, each site's secrets must live in
distinct SOPS files with distinct age recipients, so that granting access to one
site's secrets never exposes the other site's.

**Why**: a single shared secrets file makes a Bottega compromise a Casa
compromise too, and vice versa. Two independent sites need independent blast
radii.

## 2. Site LAN subnets must never overlap

Any change to IP addressing (a new VLAN, a new site LAN, a new WireGuard tunnel
subnet) must update `specs/network/topology.md` in the **same change** that
introduces it.

**Why**: overlapping subnets between Bottega and Casa break routing over the
site-to-site tunnel silently (traffic goes to the wrong side, or nowhere) and
are hard to diagnose after the fact. Making the addressing plan a single
reviewable document is the only way to catch a collision before it's applied.

## 3. WireGuard peer changes touch both ends and the peer table

Any change touching a WireGuard peer (add, remove, change AllowedIPs, rotate a
key) must update **both ends** of that peer relationship and the AllowedIPs
table in `specs/network/wireguard.md`, in the same change.

**Why**: WireGuard has no negotiation — each side's config is independent and
must agree by construction. An AllowedIPs mismatch is either a routing black
hole or an inadvertent over-broad grant, and it's invisible unless the two ends
and the spec are checked together.

## 4. MikroTik changes: idempotent, safe-mode by default

Ansible tasks against RouterOS must be idempotent (safe to re-run). Risky
changes (firewall, routing, WireGuard peers) should be applied with RouterOS
safe-mode in mind — i.e. with a way to auto-revert if the change breaks
connectivity — especially for changes to a router at a remote site.

**Why**: a bad firewall or routing rule on a MikroTik you can only reach
remotely (Casa from Bottega, or vice versa) can lock out the only path back in,
turning a config error into a physical-visit problem.

## 5. Router management interfaces: never on WAN

Router management (WinBox, WebFig, API, SSH) must only be reachable from LAN or
over VPN — never bound or exposed on a WAN interface, at either site.

**Why**: Bottega has a static public IP specifically so it can accept inbound
WireGuard connections; that same reachability must not extend to router admin
surfaces, or the whole hub becomes an internet-facing attack target.
