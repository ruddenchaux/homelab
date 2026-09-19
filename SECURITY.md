# Security

## Threat model

Public attack surface (Bottega, static IP `145.11.24.43`, see
`specs/network/firewall.md`):
- TCP `443`: dst-nat to Traefik (`10.30.0.200`). Public hostnames are only
  Jellyfin, Home Assistant, and Immich (`specs/network/dns-exposure.md`), but
  any hostname Traefik serves can be reached by setting SNI/Host, so a missing
  DNS record isn't an access control.
- UDP `61536`: WireGuard hub. It's silent to unauthenticated packets.
- Nothing else answers on WAN. Router management is LAN/VPN-only
  (`AGENTS.md` #5).

What attackers can do:
- Scan and probe TCP 443, and hit any Traefik route by SNI/Host.
- Brute-force the three public apps, which use their own logins instead of
  Authentik ForwardAuth.
- Exploit vulnerabilities in Traefik or the public apps.

What they cannot do:
- Reach Proxmox, MikroTik management, or any VLAN directly.
- Pass `traefik-internal-allowlist` from the internet. Traefik sees the real
  client IP (`externalTrafficPolicy: Local`), so internet sources are outside
  the allowed ranges.
- Bypass Authentik on ForwardAuth-protected services.

---

## Implemented security layers

### Layer 1 — Router (Bottega MikroTik)

| Measure | Details |
|---|---|
| Default-deny WAN | Only TCP `443` (forward) and UDP `61536` (input). `specs/sites/bottega.md` |
| Device-mode `home` | `fetch`, `scheduler`, `container` etc. can only be re-enabled with physical access. `specs/sites/bottega.md` |

### Layer 2 — Kubernetes / Traefik

| Measure | Tool | Status |
|---|---|---|
| Collaborative IPS + bouncer | CrowdSec (agents on every node, Traefik plugin on the `websecure` entrypoint, Console-enrolled) | Deployed — `specs/services/crowdsec.md` |
| IP allowlist for internal services | `traefik-internal-allowlist` Middleware | Deployed (effective from the internet only since `externalTrafficPolicy: Local`) |
| Rate limiting | Traefik Middleware | Planned |
| WAF / virtual patching | CrowdSec AppSec | Planned, observe-only first |

### Layer 3 — Application layer

| Measure | Tool | Details |
|---|---|---|
| SSO authentication | Authentik | ForwardAuth on all services except those with built-in auth |
| TLS everywhere | cert-manager + Let's Encrypt | DNS-01 challenge, Cloudflare |
| Services with built-in auth | Jellyfin, Seerr, NZBGet, Immich, Home Assistant | ForwardAuth disabled, native login. CrowdSec parses Jellyfin/HA/Immich auth logs |

---

## CrowdSec operations

```bash
# All via the control plane
ssh debian@10.30.0.10
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions list
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions delete --ip <ip>   # unban
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli alerts list
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli bouncers list
kubectl -n crowdsec exec ds/crowdsec-agent  -- cscli metrics
```

Emergency off switch: remove the `--entryPoints.websecure.http.middlewares`
argument in `kubernetes/platform/traefik/values.yaml`.

---

## Legacy — VPS hardening

Applies only while the Hetzner VPS still exists (see `MIGRATION.md`).

**Ansible role**: `ansible/roles/vps-hardening/`, applied by
`ansible/playbooks/vps-relay.yml` (Play 1; `--tags hardening` for hardening only).

| Measure | Tool | Details |
|---|---|---|
| Inbound firewall | UFW | Allow: 22/tcp, 51820/udp, 80/tcp, 443/tcp. Deny all else. |
| SSH brute force protection | fail2ban | Ban IP after 5 failed SSH attempts in 10 min, for 1 hour. |
| Automatic security patches | unattended-upgrades | Daily security-only upgrades, auto-reboot at 03:00 if needed. |

```bash
sudo fail2ban-client status sshd            # banned IPs
sudo fail2ban-client set sshd unbanip <ip>  # unban manually
```

---

## Future hardening

**Traefik rate limiting** (add to `kubernetes/platform/traefik/`):
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: rate-limit
  namespace: traefik
spec:
  rateLimit:
    average: 100
    burst: 50
```
