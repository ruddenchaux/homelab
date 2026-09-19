# Service spec: CrowdSec

## Summary

- **Service**: CrowdSec, a collaborative IPS. Agents parse logs and raise
  alerts, the Local API (LAPI) turns alerts into ban decisions, and bouncers
  enforce them.
- **Namespace / chart**: `kubernetes/platform/crowdsec/` (umbrella around
  `crowdsecurity/crowdsec` 0.24.2, plus `crowdsecurity/blocklist-mirror`)
- **Hostname**: `crowdsec-mirror.ruddenchaux.xyz`, for the router's list pull
  only
- **Exposure**: internal-only (split DNS). No Cloudflare record, never
  dst-natted, and further restricted to the router's VLAN 30 address (see
  Network path)

## Why

Bottega's public surface is TCP `443` → Traefik and UDP `61536` → WireGuard
(`specs/network/firewall.md`). Jellyfin, Home Assistant, and Immich are public
and use their own logins instead of Authentik ForwardAuth
(`specs/network/dns-exposure.md`), so nothing rate-limits credential stuffing
against them. CrowdSec fills that gap and adds the community blocklist.

## Architecture

```
Internet ─► MikroTik raw/prerouting: drop WAN TCP from crowdsec-a / crowdsec-b
              │ dst-nat 443 (source IP preserved)
              ▼
           Traefik (DaemonSet, externalTrafficPolicy: Local)
              │  entrypoint middleware: crowdsec-bouncer plugin (stream mode)
              ▼
           Authentik / apps
Agent DaemonSet reads /var/log/containers for traefik, jellyfin,
home-assistant, immich-server, authentik-server → LAPI (SQLite on local-path PVC)
LAPI ◄─► CrowdSec Console (enrolled: community blocklist in, signals out)
LAPI ─► Traefik plugin (stream, 30 s)
LAPI ─► blocklist-mirror ─► Traefik ─► router /tool fetch every 10 min
```

Two enforcement points, deliberately:

- **Traefik bouncer**: authoritative and fast (≤ 30 s). It sees every HTTPS
  request, and unbans take effect quickly.
- **Router**: a cheap first drop of known-bad sources before they reach the
  cluster. It lags by up to 10 min, and entries age out after 1 h if syncing
  stops.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Source IP at Traefik | `externalTrafficPolicy: Local`, Traefik as a DaemonSet with a control-plane toleration | `Cluster` SNATs public traffic to node IPs: CrowdSec would ban the nodes, and `internal-allowlist` admitted the internet as `10.30.0.0/24`. Cilium 1.19 L2 announcements ignore `Local` ("will announce the service IP on all nodes… If a node without a pod receives traffic, it will drop it"), so a pod must run on every node that can hold the lease |
| Router integration | Pull, `plain_text` format, parsed by a RouterOS script | The push bouncer needs the RouterOS API, which the base lockdown disables. The mirror's `mikrotik` format is a script run with `/import`, which would give the cluster admin rights on the router. A validated IPv4/CIDR parser only ever creates address-list entries, and rejects prefixes wider than `/16`, so a bad or poisoned decision like `0.0.0.0/0` can't blackhole all public TCP 443 |
| Router match | `raw` prerouting, `in-interface-list=WAN protocol=tcp` | TCP `443` is the only forwarded service. Leaving UDP alone keeps WireGuard `61536` open even if a shared mobile CGNAT address is listed, so the road-warrior path back in survives a false positive. `raw` doesn't touch the input chain that base lockdown rebuilds |
| Router list swap | Two lists (`crowdsec-a`, `crowdsec-b`), fill the empty one, then clear the other | A sync never leaves the router without entries. A failed fetch keeps the current list |
| Flash wear | Download to a tmpfs disk; entries are dynamic (timeout 1 h) | Nothing is written to the 512 MB NAND every 10 min |
| Mirror TLS | Pinned Let's Encrypt roots (ISRG Root X1, Root YR) imported by fingerprint | `check-certificate=yes-without-crl` without trusting a whole CA bundle. Root YR keeps working after the X1 cross-sign is dropped |
| LAPI outage | Plugin `updateMaxFailure: -1`, `streamStartupBlock: false` | A LAPI outage must not 403 every route, ArgoCD and Authentik included. The last synced cache and the router list still apply |
| Console | Enrolled (`bottega-k8s`) | Community blocklist. Signals (attacker IPs, scenario names) are shared in return |
| AppSec / WAF | Deferred | Run in observe-only mode first against Immich/HA/Jellyfin clients |

## Never banned

The agent whitelist (`homelab/whitelist`) and the plugin's
`clientTrustedIPs` both exempt `10.0.0.0/8` (VLANs, pods, WireGuard overlay
`10.99.0.0/24`) and `192.168.0.0/16` (MikroTik bridge, Casa). The agent also
exempts `145.11.24.43`.

## Auth

- ForwardAuth: none on the mirror ingress. The caller is the router, which
  can't do SSO. Access control is a `ipAllowList` of `10.30.0.1/32` (Traefik
  middleware `crowdsec-mirror-allowlist`) plus HTTP basic auth (user
  `mikrotik`).
- Secrets (`ansible/playbooks/crowdsec-secrets.yml`):
  - The LAPI secret, registration token, and both bouncer keys are generated
    in-cluster once and kept.
  - The Console enroll key and mirror password come from
    `ansible/secrets/bottega.sops.yml` (`bottega_crowdsec_enroll_key`,
    `bottega_crowdsec_mirror_password`), per `AGENTS.md` #1.
  - The chart's `secrets.externalSecret` points at them, because its
    `lookup`-based generation would rotate on every ArgoCD sync.

## Storage

- LAPI data 1Gi and config 100Mi, `local-path`.

## Network path

- Logs: node `/var/log/containers` → agent → LAPI (`crowdsec-service.crowdsec:8080`).
- Router pull: MikroTik `10.30.0.1` → `crowdsec-mirror.ruddenchaux.xyz`
  (router split DNS → `10.30.0.200`) → Traefik → allowlist + basic auth →
  mirror `:41412`.

## Certificate

- `letsencrypt-prod`, `crowdsec-mirror-tls`.

## Implementation

| Piece | Where |
|---|---|
| Traefik source IP, access logs, plugin, entrypoint middleware | `kubernetes/platform/traefik/values.yaml`, `templates/crowdsec-middleware.yaml` |
| Engine + mirror | `kubernetes/platform/crowdsec/`, `kubernetes/apps/templates/crowdsec.yaml` |
| Secrets | `ansible/roles/crowdsec-secrets/`, `ansible/playbooks/crowdsec-secrets.yml` |
| Router | `ansible/roles/bottega_crowdsec/`, `ansible/playbooks/bottega-crowdsec.yml` |

Order: `crowdsec-secrets.yml` → push/sync (Traefik + crowdsec apps) →
verify the cluster criteria → `bottega-crowdsec.yml` under safe mode.

## Acceptance criteria

Run kubectl as `ssh debian@10.30.0.10 'kubectl …'`.

- [ ] From cellular, a request to `jellyfin.ruddenchaux.xyz` shows up in
      Traefik's JSON access log with the phone's public IP as `ClientHost`,
      not `10.30.0.x`.
- [ ] From cellular,
      `curl --resolve loki.ruddenchaux.xyz:443:145.11.24.43 https://loki.ruddenchaux.xyz/`
      returns 403 (`internal-allowlist` now holds for internet sources).
- [ ] `kubectl -n traefik get pods -o wide` shows one Traefik pod per node,
      `k8s-ctrl-01` included.
- [ ] `cscli metrics` in the LAPI pod shows lines parsed for `traefik`, and
      for each of `jellyfin`, `home-assistant`, `immich`, `authentik` once
      they have logged anything.
- [ ] `cscli bouncers list` shows `traefik` and `mirror`, both with a recent
      last pull. `cscli console status` shows the instance enrolled.
- [ ] `cscli decisions add --ip <phone cellular IP> -d 5m` makes the phone
      get 403 from Traefik within 30 s, while a VLAN 20 client is unaffected.
- [ ] Within 10 min, `:global bottegaCrowdsecLastSync; :put $bottegaCrowdsecLastSync`
      starts with `ok`. The phone's TCP 443 then times out while its
      WireGuard profile still connects. `cscli decisions delete --ip …`
      restores access after the next sync.
- [ ] The mirror URL answers 403 from any host other than `10.30.0.1`
      (e.g. from VLAN 20), and 401 without credentials from the router.
- [ ] An external `nmap -Pn 145.11.24.43` still shows only TCP `443` and UDP
      `61536`. The base-lockdown readback still passes, so the input chain is
      unchanged.

## Open

- `TODO(fact):` Jellyfin, Immich, and Home Assistant must log the real client
  IP (from `X-Forwarded-For` sent by Traefik) for their brute-force scenarios
  to trigger. If an app logs Traefik's pod IP instead, the whitelist drops
  the event silently. Check each app's trusted-proxy setting against
  `10.0.0.0/16` once real IPs reach Traefik.
- `TODO(fact):` RouterOS script policy `ftp,read,write,test` is assumed to be
  enough for `/tool fetch` into tmpfs. The role's validate step fails loudly
  if it isn't.
