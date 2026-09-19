# Service spec: CrowdSec

## Summary

- **Service**: CrowdSec, a collaborative IPS. Agents parse logs and raise
  alerts, the Local API (LAPI) turns alerts into ban decisions, and the
  Traefik bouncer enforces them.
- **Namespace / chart**: `kubernetes/platform/crowdsec/` (umbrella around
  `crowdsecurity/crowdsec` 0.24.2)
- **Hostname**: none. LAPI is cluster-internal only
  (`crowdsec-service.crowdsec:8080`).
- **Exposure**: internal-only

## Why

Bottega's public surface is TCP `443` → Traefik and UDP `61536` → WireGuard
(`specs/network/firewall.md`). Jellyfin, Home Assistant, and Immich are public
and use their own logins instead of Authentik ForwardAuth
(`specs/network/dns-exposure.md`), so nothing rate-limits credential stuffing
against them. CrowdSec fills that gap and adds the community blocklist.

## Architecture

```
Internet ─► MikroTik dst-nat 443 (source IP preserved)
              ▼
           Traefik (DaemonSet, externalTrafficPolicy: Local)
              │  entrypoint middleware: crowdsec-bouncer plugin (stream mode)
              ▼
           Authentik / apps
Agent DaemonSet reads /var/log/containers for traefik, jellyfin,
home-assistant, immich-server, authentik-server → LAPI (SQLite on local-path PVC)
LAPI ◄─► CrowdSec Console (enrolled: community blocklist in, signals out)
LAPI ─► Traefik plugin (stream, 30 s)
```

Traefik is the only enforcement point. It sees every HTTPS request, bans
apply within 30 s, and unbans are just as fast.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Source IP at Traefik | `externalTrafficPolicy: Local`, Traefik as a DaemonSet with a control-plane toleration | `Cluster` SNATs public traffic to node IPs: CrowdSec would ban the nodes, and `internal-allowlist` admitted the internet as `10.30.0.0/24`. Cilium 1.19 L2 announcements ignore `Local` ("will announce the service IP on all nodes… If a node without a pod receives traffic, it will drop it"), so a pod must run on every node that can hold the lease |
| Enforcement point | Traefik only; **no router enforcement** | See "Router enforcement: rejected" below |
| LAPI outage | Plugin `updateMaxFailure: -1`, `streamStartupBlock: false` | A LAPI outage must not 403 every route, ArgoCD and Authentik included. The last synced cache still applies |
| Console | Enrolled (`bottega-k8s`) | Community blocklist. Signals (attacker IPs, scenario names) are shared in return |
| AppSec / WAF | Deferred | Run in observe-only mode first against Immich/HA/Jellyfin clients |

### Router enforcement: rejected (2026-09-19)

The plan was to have the Bottega MikroTik pull the ban list from an
in-cluster `blocklist-mirror` every 10 min and drop listed sources in
`raw`/prerouting. It was built, and removed before it ever installed, because:

- It needs `/tool fetch` and `/system scheduler`, and Bottega's device-mode is
  `home`, which disables both (`specs/sites/bottega.md`). Re-enabling them
  needs physical access, and weakens the protection home mode exists for:
  scheduled fetch-and-run is the persistence pattern used in past mass
  compromises of MikroTik routers.
- The gain is small. Only TCP `443` is forwarded, and Traefik already blocks
  banned sources within 30 s. The router would mostly save cluster CPU.
- The push alternative (`cs-mikrotik-bouncer`) needs the RouterOS API, which
  the base lockdown disables, and would let a cluster compromise write router
  config.

Revisit only if the router's device-mode changes for another reason, or if
ban volume makes Traefik's CPU a real concern. The removed implementation is
in git history (commits `2a3c29f`, `8490b9b`, `cd44408`).

## Never banned

The agent whitelist (`homelab/whitelist`) and the plugin's
`clientTrustedIPs` both exempt `10.0.0.0/8` (VLANs, pods, WireGuard overlay
`10.99.0.0/24`) and `192.168.0.0/16` (MikroTik bridge, Casa). The agent also
exempts `145.11.24.43`.

## Auth

- There's no ingress, so no ForwardAuth.
- Secrets (`ansible/playbooks/crowdsec-secrets.yml`):
  - The LAPI secret, registration token, and Traefik bouncer key are
    generated in-cluster once and kept.
  - The Console enroll key comes from `ansible/secrets/bottega.sops.yml`
    (`bottega_crowdsec_enroll_key`), per `AGENTS.md` #1.
  - The chart's `secrets.externalSecret` points at them, because its
    `lookup`-based generation would rotate on every ArgoCD sync.
  - **The secrets must exist before ArgoCD syncs Traefik.** Traefik mounts
    `crowdsec-bouncer`; without it the pods can't start and all ingress goes
    down.

## Storage

- LAPI data 1Gi and config 100Mi, `local-path`.

## Network path

- Logs: node `/var/log/containers` → agent → LAPI (`crowdsec-service.crowdsec:8080`).
- Decisions: LAPI → Traefik plugin, stream mode, every 30 s.

## Implementation

| Piece | Where |
|---|---|
| Traefik source IP, access logs, plugin, entrypoint middleware | `kubernetes/platform/traefik/values.yaml`, `templates/crowdsec-middleware.yaml` |
| Engine | `kubernetes/platform/crowdsec/`, `kubernetes/apps/templates/crowdsec.yaml` |
| Secrets | `ansible/roles/crowdsec-secrets/`, `ansible/playbooks/crowdsec-secrets.yml` |

## Acceptance criteria

Run kubectl as `ssh debian@10.30.0.10 'kubectl …'`. Verified 2026-09-19
unless marked open.

- [x] From cellular, a request to `jellyfin.ruddenchaux.xyz` shows up in
      Traefik's JSON access log with the phone's public IP as `ClientHost`,
      not `10.30.0.x`.
- [x] From cellular,
      `curl --resolve loki.ruddenchaux.xyz:443:145.11.24.43 https://loki.ruddenchaux.xyz/`
      returns 403 (`internal-allowlist` now holds for internet sources).
- [x] `kubectl -n traefik get pods -o wide` shows one Traefik pod per node,
      `k8s-ctrl-01` included.
- [x] `cscli bouncers list` shows the Traefik bouncer on every Traefik pod,
      with a recent last pull. `cscli console status` shows the instance
      enrolled.
- [x] `cscli decisions add --ip <phone cellular IP> -d 5m` makes the phone
      get 403 from Traefik within 30 s. `cscli decisions delete --ip …`
      lifts it.
- [x] A failed login from cellular on Jellyfin, Home Assistant, and Immich
      is logged by each app with the client's public IP, parsed by its hub
      parser, and poured into its brute-force scenario (`jellyfin-bf`,
      `home-assistant-bf`, `immich-bf`).

## Open

- `TODO(decision):` Jellyfin's `KnownProxies = 10.0.0.0/16` was set by hand
  in the UI (2026-09-19). It isn't in IaC yet: the `media-config` role can't
  authenticate, because its default admin password no longer matches. Until
  it is, a rebuilt Jellyfin logs Traefik's pod IP and its brute-force
  detection silently stops. Jellyfin only reads `KnownProxies` at startup, so
  a restart is needed after changing it.
- Home Assistant (`trusted_proxies: 10.0.0.0/16` in its ConfigMap) and Immich
  (trusts private proxies by default) log real IPs with no extra config.
- Immich's SSO login (`oauthAutoLaunch`) doesn't work from outside the VPN:
  `auth.ruddenchaux.xyz` has no public record. Its password endpoint is still
  public, which is why `immich-bf` matters.
