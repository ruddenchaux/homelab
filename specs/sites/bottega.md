# Site: Bottega

## Role

**Hub.** Terminates WireGuard from Casa and the road-warrior peer. Is the
DNS/ingress entry point for all services. The only site directly reachable from
the internet.

## Connectivity

- Flynet PPPoE fiber, **static public IPv4**.
- Router: MikroTik hAP be3 Media, RouterOS 7 — see `## Router hardware` below.

## Router hardware

MikroTik **hAP be3 Media** (`MA53UG+HbeH`), RouterOS v7.

| Property | Value |
|---|---|
| CPU | Qualcomm IPQ-5322, quad-core ARM 64-bit, up to 1.5 GHz |
| RAM / storage | 2 GB DDR4 / 512 MB NAND |
| Ethernet | 5x 2.5G RJ45 — **no SFP/SFP+** |
| PoE | PoE-in 24–57 V, 802.3af/at (one port); DC jack also present |
| Wireless | Tri-band Wi-Fi 7 (2.4 / 5 / 6 GHz), 2x2 MIMO per band |
| Other | USB-C + 2x USB-A 3.0, microSD, Bluetooth 5.4, Matter/Thread radio |
| Containers | Supported (ARM64 container runtime in RouterOS 7) |

Source: official MikroTik user manual for hAP be³ Media (`help.mikrotik.com`,
UM page 357302341) and the product specification page.

Recorded as capability, **not designed here**:

- ARM64 + container support means small always-on workloads (a DNS resolver,
  an external-check agent) could run on the router rather than in the k8s
  cluster. No decision — noted so the option isn't forgotten.
- **Wi-Fi is a deferred task.** Tri-band Wi-Fi 7 is available; SSIDs, bands,
  VLAN-to-SSID mapping and guest isolation are designed nowhere yet.

### No SFP — consequence for the server uplink

The L009 in use today has a 2.5G-capped SFP port, which is why the R740xd is
currently cabled at 1G on a BCM5720 port (`CLAUDE.md`). The hAP be3 has no SFP
at all — every port is 2.5G copper, so the uplink is RJ45 regardless.

- `TODO(fact):` confirm what the server NIC negotiates against a 2.5G copper
  port. The BCM57416 is 10GBASE-T and may not fall back to 2.5G (NBASE-T is
  not guaranteed); the BCM5720 is 1G-only. If neither negotiates 2.5G the
  uplink stays 1G — a capacity fact worth knowing before the move, not a
  blocker.

## Port roles

Verified against the official manual: the factory configuration makes
**Ethernet1** the WAN port (firewall-protected, DHCP client, MAC
connection/discovery disabled on it); all other Ethernet ports and the wireless
interfaces join the LAN bridge at `192.168.88.1/24`.

| Port | Role | Notes |
|---|---|---|
| Ethernet1 | **WAN** | PPPoE to Flynet, static public IP. Keeps the factory WAN role — no re-cabling of the default. Bring-up is a separate task |
| Ethernet5 | **R740xd uplink** | Kubernetes VLAN 30 — see `specs/network/topology.md` for addressing. 2.5G copper |
| Ethernet2–4 | **LAN / trunk + management** | VLAN trunk and management access. VLAN design is a separate task |

`ether5` for the server is a labelling convention only — farthest port from
WAN, so a mis-cabled uplink is visibly wrong. Free to change before the build;
once chosen, cabling, labels, and Ansible must agree.

- `TODO(fact):` confirm the literal RouterOS interface names with
  `/interface ethernet print` on first boot. The manual says "Ethernet1" in
  prose but never prints the interface-name strings; `ether1`…`ether5` is
  MikroTik convention, not a documented fact for this model. Everything below
  is written against `ether1`…`ether5` and must be re-checked before it
  becomes Ansible.
- `TODO(fact):` confirm which physical port is PoE-in. Retail spec sheets say
  Port 1; the official manual gives only "PoE-in 24–57 V, 802.3af/at" without
  naming the port. Non-blocking — the router is powered from the DC jack.

## Interface lists

Two lists, referenced by every lockdown rule below:

| List | Members at base-lockdown | Grows later with |
|---|---|---|
| `WAN` | `ether1` | the PPPoE interface (see below) |
| `LAN` | `bridge` (carrying `ether2`–`ether5` + wireless) | VLAN interfaces (VLAN task), the WireGuard interface (WireGuard task) |

**WAN-list membership is the security boundary.** The input chain accepts
anything whose in-interface is *not* in `WAN`, so an interface in neither list
is treated as trusted. Two consequences:

- Deliberate and correct: the future WireGuard interface becomes trusted for
  input the moment it exists — which is what `specs/network/firewall.md`
  already asserts ("LAN / VPN → router management: yes").
- **Trap for the PPPoE task**: with PPPoE, decapsulated traffic arrives with
  `in-interface` set to the *PPPoE* interface, not `ether1`. If that interface
  is not added to the `WAN` list, the final drop rule stops matching and the
  entire lockdown silently fails open. The PPPoE task must add it and re-run
  the external acceptance check.

## What lives here

The entire current lab moves here as a physical unit:

- Dell R740xd (Proxmox host), full k8s cluster (control plane + workers)
- All platform/media/app services currently deployed via ArgoCD
- VLANs 10 (mgmt), 20 (trusted LAN), 30 (kubernetes) — see
  `specs/network/topology.md`

## Responsibilities as hub

- Accept inbound WireGuard from Casa (spoke) and the road-warrior peer.
- Route traffic between remote peers and the appropriate local VLAN, per
  `specs/network/firewall.md`.
- Own the public DNS-facing IP for any service that needs raw-internet
  exposure (`specs/network/dns-exposure.md`).
- Never expose its own router management interface to WAN
  (`AGENTS.md` rule #5) — the static IP is for the WireGuard/service path
  only.

## Connectivity fact

Bottega's public IP is contractually static: `145.11.24.43`. No DDNS or
mitigation is needed for IP instability; the only ongoing concern is
reachability monitoring, tracked as `TODO(fact):` in
`specs/observability/external-checks.md`, not here.

## Base management lockdown

**Intent**: a freshly-installed hAP be3 whose management plane is reachable
only from the local LAN and never from WAN, with a layer-2 escape hatch
preserved on the LAN side so a bad rule cannot permanently lock out the
operator.

Applied per `.claude/skills/mikrotik-safe-change.md` — safe mode on, since
every rule here can lock out the session applying it.

Implemented by `ansible/playbooks/bottega-base-lockdown.yml`; implementation
notes live in `ansible/roles/mikrotik-bottega-base-lockdown/README.md`.

### Services

`/ip service`:

- `www`, `ssh`, `winbox` → `address=192.168.88.0/24`
- `telnet`, `ftp`, `api`, `api-ssl`, `www-ssl` → disabled
- RouterOS `reverse-proxy`, if present → disabled

Disabling `www-ssl` and `reverse-proxy` also leaves the router's own TCP `443`
unbound, so the later dst-nat task never has to reason about a local service on
that port.

### Input chain

Exactly four rules, in this order:

1. `accept connection-state=established,related`
2. `drop connection-state=invalid`
3. `accept in-interface-list=!WAN`
4. `drop in-interface-list=WAN` ← **must remain the last rule**

Future WAN exceptions are *inserted before* rule 4, never appended after it.

### Credentials

- The factory `admin` account ships with a blank password. That state must not
  survive first boot.
- Interactive auth is key-based: an ed25519 public key is imported for `admin`
  and `/ip ssh set always-allow-password-login=no`, so SSH accepts keys only.
- A strong password is still set for `admin` and stored in Bottega's SOPS file
  (`AGENTS.md` #1) — WinBox and the serial console have no key auth. Its
  purpose is console/WinBox recovery, not routine access.

### MAC-layer access — restricted, not disabled

    /tool mac-server set allowed-interface-list=LAN
    /tool mac-server mac-winbox set allowed-interface-list=LAN
    /ip neighbor discovery-settings set discover-interface-list=LAN

**Rationale — deliberate; do not "harden" these to `none`.** MAC-Winbox
reachable from WAN is a real backdoor: it bypasses IP filtering entirely.
MAC-Winbox reachable from the LAN is the layer-2 recovery path — if a firewall
or addressing mistake strips the operator's IP connectivity, a
directly-attached laptop can still reach the router by MAC and undo it, without
a factory reset. Scoping the lists to `LAN` closes the backdoor and keeps the
escape hatch. Setting them to `none` closes both.

One exception worth knowing: `/tool mac-server ping` is a global on/off toggle
with no interface list. It stays enabled as part of the same recovery path; it
is the only MAC-layer item that cannot be LAN-scoped.

## Phasing: what is open on WAN, and when

`specs/network/firewall.md` records the **end state** — default-deny from WAN
with exactly two exceptions (WireGuard UDP `61536` and TCP `443`). This spec
asserts those ports are **closed**. Both are correct: they describe different
phases of the same router.

| Phase | Task | WAN answers |
|---|---|---|
| 1 | Base lockdown (this spec) | nothing |
| 2 | PPPoE / WAN bring-up | nothing — link comes up, lockdown holds; PPPoE interface joins the `WAN` list |
| 3 | dst-nat / public exposure | + TCP `443` — dst-nat in prerouting, then the **forward** chain, not an input exception |
| 4 | WireGuard | + UDP `61536`, an input-chain accept inserted before the final drop |

The acceptance script must be phase-aware: "nothing answers on WAN" is the
correct result at phases 1–2, relaxing to "only TCP `443`" at phase 3 and
"only TCP `443` + UDP `61536`" at phase 4. A scan showing nothing open before
phase 3 is a pass, not a regression.

## Deferred (noted, not decided here)

- **Tighten `/ip service` from `192.168.88.0/24` to the management VLAN
  `10.10.0.0/24`** — belongs to the VLAN task, once VLAN 10 exists at Bottega.
  Until then `192.168.88.0/24` is the only LAN that exists.
- **Wi-Fi** — SSIDs, bands, VLAN mapping, guest isolation. Nothing designed.
- **Proxmox management over the server link** — `ether5` is spec'd as the
  kubernetes-VLAN uplink, but Proxmox's own management lives on VLAN 10.
  Whether that single physical link is an access port or a tagged trunk
  carrying 10/20/30 (as `ether6` does on the L009 today) is a VLAN-task
  decision.
- PPPoE/WAN bring-up, VLANs, dst-nat, WireGuard — separate tasks.

## Move logistics

Decided: a parallel run at both sites, with cutover only after Bottega passes
its acceptance criteria below. No live migration — power down at Casa, move
the hardware, power up at Bottega. See `MIGRATION.md` for the full ordering.

- `TODO(fact):` move date — not yet scheduled, non-blocking.

## Acceptance criteria

Split by vantage point. The WAN-closure assertions are **not testable from the
LAN** — a connection to the public IP from inside is subject to NAT-loopback
and proves nothing about what the internet sees.

### Internal — from a host on `192.168.88.0/24`

- [ ] `/ip service print` shows `www`, `ssh`, `winbox` with
      `address=192.168.88.0/24`, and `telnet`, `ftp`, `api`, `api-ssl`,
      `www-ssl`, plus `reverse-proxy` if present, all flagged `X`
      (disabled).
- [ ] `/ip firewall filter print chain=input` returns exactly the four rules
      above, in that order, with `drop in-interface-list=WAN` last.
- [ ] `/interface list member print` shows `ether1` in `WAN`, `bridge` in
      `LAN`, and no interface in both.
- [ ] `/tool mac-server print`, `/tool mac-server mac-winbox print` and
      `/ip neighbor discovery-settings print` show `allowed-interface-list=LAN`
      / `discover-interface-list=LAN` — **not** `none`, **not** `all`.
- [ ] `/user ssh-keys print where user=admin` returns at least one key, and
      `/ip ssh print` shows `always-allow-password-login: no`.
- [ ] `ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password admin@192.168.88.1`
      is refused, while `ssh admin@192.168.88.1` with the key succeeds.
- [ ] `nc -z -w2 192.168.88.1 22` and `nc -z -w2 192.168.88.1 8291` both
      succeed — the operator is not locked out.
- [ ] From a laptop cabled to `ether2`–`ether5` with **no IP configured**,
      WinBox in MAC mode discovers and connects — the layer-2 escape hatch
      works.

### External — from outside the network

Vantage point: a phone on cellular, or the Hetzner VPS (`89.167.62.126`, still
up until decommission per `MIGRATION.md`) — never from the LAN. Gated on WAN
being up, i.e. runnable after the PPPoE task, not at the end of this one.

- [ ] `nmap -Pn -p 22,80,443,8291 145.11.24.43` — none open.
- [ ] `nmap -Pn -p 8728,8729 145.11.24.43` — neither open.
- [ ] Phase-aware re-runs: after phase 3, only TCP `443` is open and UDP
      `61536` is still closed/filtered; after phase 4, only TCP `443` + UDP
      `61536` are open.

### Move / hub

- [ ] Bottega's WireGuard endpoint is reachable from Casa and the road-warrior
      peer (see `specs/network/wireguard.md`).
- [ ] All services previously reachable at the home site are reachable
      identically once the lab is physically at Bottega (same hostnames, same
      internal resolution behavior).
