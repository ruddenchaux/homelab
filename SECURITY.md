# Security

## Threat model

Public attack surface:
- VPS (89.167.62.126): ports 80/443 (nginx TCP relay), 22 (SSH), 51820/udp (WireGuard)
- All homelab internals are NOT directly exposed — nginx is a blind TCP passthrough to the
  WireGuard tunnel. The VPS cannot inspect TLS payload or HTTP content.
- Traefik handles TLS termination inside the cluster and routes to pods.

What attackers can do:
- Scan and probe VPS ports 80/443 (hits nginx → WireGuard → Traefik)
- Brute-force SSH on the VPS
- Attempt to exploit vulnerabilities in unpatched VPS software
- Send malicious traffic that reaches Traefik (mitigated by Authentik ForwardAuth)

What they cannot do:
- Reach Proxmox, MikroTik, or any homelab VLAN directly (not routed from public internet)
- Bypass Authentik — all services except Jellyfin, Seerr, NZBGet require SSO login
- See hostnames or routes — nginx TCP stream is SNI-blind, Traefik does the routing internally

---

## Implemented security layers

### Layer 1 — VPS hardening (Tier 1)

**Ansible role**: `ansible/roles/vps-hardening/`
**Applied by**: `ansible/playbooks/vps-relay.yml` (Play 1)

| Measure | Tool | Details |
|---|---|---|
| Inbound firewall | UFW | Allow: 22/tcp, 51820/udp, 80/tcp, 443/tcp. Deny all else. |
| SSH brute force protection | fail2ban | Ban IP after 5 failed SSH attempts in 10 min, for 1 hour. |
| Automatic security patches | unattended-upgrades | Daily security-only upgrades, auto-reboot at 03:00 if needed. |

### Layer 2 — Kubernetes / Traefik (planned — Tier 2)

| Measure | Tool | Status |
|---|---|---|
| Rate limiting | Traefik Middleware | Planned |
| IP allowlist for internal services | Traefik Middleware | Planned |
| Collaborative IPS + Traefik bouncer | CrowdSec | Planned |

### Layer 3 — Application layer (deployed)

| Measure | Tool | Details |
|---|---|---|
| SSO authentication | Authentik | ForwardAuth on all services except those with built-in auth |
| TLS everywhere | cert-manager + Let's Encrypt | DNS-01 challenge, Cloudflare |
| Services with built-in auth | Jellyfin, Seerr, NZBGet | ForwardAuth disabled, native login |

---

## Running the hardening playbook

The VPS hardening role runs automatically as part of `vps-relay.yml`:

```bash
ansible-playbook ansible/playbooks/vps-relay.yml
```

To run hardening only (without reconfiguring WireGuard/nginx):

```bash
ansible-playbook ansible/playbooks/vps-relay.yml --tags hardening
```

---

## Monitoring fail2ban

```bash
# SSH into VPS, then:
sudo fail2ban-client status sshd       # banned IPs
sudo fail2ban-client set sshd unbanip <ip>  # unban manually
sudo journalctl -u fail2ban -f         # live log
```

---

## Future hardening (Tier 2 — CrowdSec + Traefik)

CrowdSec is a collaborative IPS. The recommended architecture:

```
Internet → VPS nginx (CrowdSec agent parses logs)
                    ↓ WireGuard
           Traefik (CrowdSec bouncer blocks IPs before hitting apps)
```

Steps when implementing:
1. Install CrowdSec agent on VPS (`crowdsec` package)
2. Install CrowdSec Traefik bouncer in k8s (Helm chart: `crowdsec/crowdsec`)
3. Add `crowdsec-traefik-bouncer` middleware globally in Traefik
4. Enroll VPS in CrowdSec console (free tier) for community blocklists

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

**Traefik IP allowlist for internal-only services** (ArgoCD, Grafana, Hubble):
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: internal-only
  namespace: traefik
spec:
  ipAllowList:
    sourceRange:
      - 10.10.0.0/24   # Management VLAN
      - 10.20.0.0/24   # Trusted LAN
      - 10.30.0.0/24   # Kubernetes VLAN
      - 10.100.0.0/24  # WireGuard clients (road warrior VPN)
```
