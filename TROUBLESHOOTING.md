# Troubleshooting

## Cilium L2 LoadBalancer IPs unreachable

If services with `type: LoadBalancer` get an external IP but it's not reachable, Cilium L2 announcements may not be active. Check for config drift:

```bash
# Check if Cilium detected a config mismatch (l2 enabled in configmap but not in running agent)
ssh debian@10.30.0.10 "kubectl -n kube-system logs ds/cilium | grep -i 'mismatch\|l2'"

# Verify L2 leases exist (one per LoadBalancer service)
ssh debian@10.30.0.10 "kubectl get leases -n kube-system | grep l2"

# If no leases, restart Cilium to pick up config changes
ssh debian@10.30.0.10 "kubectl -n kube-system rollout restart daemonset/cilium"
ssh debian@10.30.0.10 "kubectl -n kube-system rollout status daemonset/cilium --timeout=300s"
```

## Re-running `kubernetes-install.yml` resets Cilium config (LoadBalancer IPs go dark)

The `k8s-control-plane` role's `Install Cilium` task runs `helm upgrade --install cilium --set operator.replicas=1` **without `--reuse-values`**. The `cilium-l2` role later layers on `l2announcements.enabled`, `externalIPs.enabled`, `hubble.relay.enabled`, `hubble.ui.enabled` via `--reuse-values`. If you ever re-run `kubernetes-install.yml` (e.g. to add a new worker node), the control-plane play wipes those layered values back to chart defaults, the new Cilium pod boots with `enable-l2-announcements=false`, and no node will announce the LB IP for any Service. Symptom: every ingress hostname returns "connection refused" / curl times out from outside the cluster, even though pods/services look healthy.

Fix: re-apply the L2 + Hubble values, then restart Cilium:

```bash
ssh debian@10.30.0.10 "helm repo add cilium https://helm.cilium.io/ 2>/dev/null; \
  helm repo update cilium && \
  helm upgrade cilium cilium/cilium \
    --namespace kube-system --reuse-values --version 1.19.0 \
    --set l2announcements.enabled=true \
    --set externalIPs.enabled=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true && \
  kubectl -n kube-system rollout restart daemonset/cilium && \
  kubectl -n kube-system rollout status daemonset/cilium --timeout=300s"
```

Permanent fix (when you next touch the role): add `--reuse-values` to the `helm upgrade` line in `ansible/roles/k8s-control-plane/tasks/main.yml` so re-runs preserve any later customizations.

## ArgoCD application stuck on Unknown/OutOfSync

ArgoCD caches the Git repo. If you just pushed changes and the application hasn't synced:

```bash
# Force a hard refresh (re-fetch from Git)
ssh debian@10.30.0.10 "kubectl -n argocd patch application <app-name> \
  --type merge -p '{\"metadata\":{\"annotations\":{\"argocd.argoproj.io/refresh\":\"hard\"}}}'"

# Check application sync status and errors
ssh debian@10.30.0.10 "kubectl get applications -n argocd"

# View detailed error message for a specific application
ssh debian@10.30.0.10 "kubectl get application <app-name> -n argocd \
  -o jsonpath='{.status.conditions[*].message}'"
```

## TLS certificate not issued

If the browser shows "not secure" after setting up an ingress with cert-manager:

```bash
# Check certificate status (should be True)
ssh debian@10.30.0.10 "kubectl get certificate -A"

# Check certificate request status
ssh debian@10.30.0.10 "kubectl get certificaterequest -A"

# Check for errors in cert-manager logs
ssh debian@10.30.0.10 "kubectl logs -n cert-manager deploy/cert-manager --tail=50"

# Verify ClusterIssuers are ready
ssh debian@10.30.0.10 "kubectl get clusterissuer"

# Check challenge status (DNS-01 challenges can take a minute)
ssh debian@10.30.0.10 "kubectl get challenges -A"
```

## Traefik not routing traffic

If Traefik has an external IP but returns 404 for all requests:

```bash
# Verify Traefik is running and has a LoadBalancer IP
ssh debian@10.30.0.10 "kubectl get svc -n traefik"
ssh debian@10.30.0.10 "kubectl get pods -n traefik"

# Check IngressRoutes and Ingresses
ssh debian@10.30.0.10 "kubectl get ingressroute -A"
ssh debian@10.30.0.10 "kubectl get ingress -A"

# Test connectivity to Traefik from within the cluster
ssh debian@10.30.0.10 "curl -s -o /dev/null -w '%{http_code}' http://10.30.0.200"
```

## Subdomains not resolving (DNS)

Cloudflare A records pointing to private IPs (e.g. `10.30.0.200`) can get stuck in DNS caches — both on MikroTik and in the browser. If a subdomain was queried before the Cloudflare record existed, the negative response gets cached.

```bash
# Flush MikroTik DNS cache
ssh admin@192.168.88.1 "/ip dns cache flush"

# Check what DNS servers MikroTik is using
ssh admin@192.168.88.1 "/ip dns print"
```

If flushing doesn't help, try a browser incognito window or restart the MikroTik DNS service. As a last resort, a server reboot clears all caches.

## Loki: read-only filesystem errors

Loki defaults `common.path_prefix` to `/var/loki`, but the container runs with a read-only root filesystem. Without a PersistentVolume (no StorageClass/CSI driver), Loki crashes with `mkdir /var/loki: read-only file system`.

**Fix:** Redirect all Loki data paths to `/tmp/loki`, which has an existing emptyDir volume mount. In `kubernetes/platform/loki/values.yaml`:

```yaml
loki:
  loki:
    commonConfig:
      path_prefix: /tmp/loki
    storage:
      filesystem:
        chunks_directory: /tmp/loki/chunks
        rules_directory: /tmp/loki/rules
  singleBinary:
    persistence:
      enabled: false
```

If Loki is stuck after a values change (StatefulSet volumeClaimTemplates are immutable), delete the StatefulSet so ArgoCD recreates it:

```bash
# Check what's blocking the pod
ssh debian@10.30.0.10 "kubectl describe pod loki-0 -n loki | tail -10"

# Check Loki container logs for filesystem errors
ssh debian@10.30.0.10 "kubectl logs loki-0 -n loki -c loki --tail=20"

# Check if there's a stuck PVC
ssh debian@10.30.0.10 "kubectl get pvc -n loki"

# Delete the StatefulSet to let ArgoCD recreate it with updated config
ssh debian@10.30.0.10 "kubectl delete statefulset loki -n loki"

# Force ArgoCD to re-render the chart from latest Git
ssh debian@10.30.0.10 "kubectl -n argocd patch application loki \
  --type merge -p '{\"metadata\":{\"annotations\":{\"argocd.argoproj.io/refresh\":\"hard\"}}}'"

# Verify the configmap has the updated paths
ssh debian@10.30.0.10 "kubectl get configmap loki -n loki -o yaml | grep path_prefix"

# Confirm pod is running
ssh debian@10.30.0.10 "kubectl get pods -n loki"
```

**Note:** Data is ephemeral with emptyDir — logs are lost on pod restart. Add a StorageClass (e.g. local-path-provisioner or Longhorn) for persistence.

## Metrics-server: kubelet TLS verification failed

metrics-server can't scrape kubelets if their self-signed certificates don't include IP SANs (standard with kubeadm):

```
Failed to scrape node: tls: failed to verify certificate: x509: cannot validate certificate for 10.30.0.x because it doesn't contain any IP SANs
```

**Fix:** Add `--kubelet-insecure-tls` in `kubernetes/platform/metrics-server/values.yaml`:

```yaml
metrics-server:
  args:
    - --kubelet-insecure-tls
```

```bash
# Check metrics-server logs for TLS errors
ssh debian@10.30.0.10 "kubectl logs -n kube-system deployment/metrics-server --tail=20"

# Check if the metrics API is registered
ssh debian@10.30.0.10 "kubectl get apiservices | grep metrics"

# Verify metrics are working
ssh debian@10.30.0.10 "kubectl top nodes"
ssh debian@10.30.0.10 "kubectl top pods -A"
```

This is safe in a private homelab network. The flag skips kubelet certificate verification but traffic is still encrypted.

## Authentik: Helm existingSecret replaces entire config

The Authentik chart's `authentik.existingSecret` replaces the **entire** chart-generated Secret (which contains `AUTHENTIK_POSTGRESQL__HOST`, `AUTHENTIK_LOG_LEVEL`, and ~15 other env vars). If your secret only has the sensitive keys, Authentik falls back to defaults (PostgreSQL host = `localhost`) and crashes.

**Fix:** Don't use `existingSecret`. Instead, use `global.envFrom` to inject only the sensitive values while letting the chart manage the rest:

```yaml
# values.yaml (umbrella chart)
authentik:
  global:
    envFrom:
      - secretRef:
          name: authentik-credentials   # only AUTHENTIK_SECRET_KEY + AUTHENTIK_POSTGRESQL__PASSWORD
  authentik:
    secret_key: ""                      # overridden by envFrom
    postgresql:
      password: ""                      # overridden by envFrom
```

```bash
# Verify the chart-generated secret has all config keys
ssh debian@10.30.0.10 "kubectl get secret authentik -n authentik -o jsonpath='{.data}' | python3 -c \"import json,sys,base64; d=json.load(sys.stdin); [print(k) for k in sorted(d.keys())]\""

# Verify the pod has AUTHENTIK_POSTGRESQL__HOST set correctly
ssh debian@10.30.0.10 "kubectl exec deploy/authentik-server -n authentik -- env | grep AUTHENTIK_POSTGRESQL__HOST"
```

The pre-created secret must use the chart's env var naming convention:
- `AUTHENTIK_SECRET_KEY` (not `authentik-secret-key`)
- `AUTHENTIK_POSTGRESQL__PASSWORD` (double underscore, not `authentik-postgresql-password`)

## Authentik: StatefulSet immutable field error

When toggling PostgreSQL persistence (`persistence.enabled: true → false`), ArgoCD fails with:

```
StatefulSet.apps "authentik-postgresql" is invalid: spec: Forbidden: updates to statefulset spec for fields other than 'replicas', 'template', 'updateStrategy' ...
```

**Fix:** Delete the StatefulSet and its PVC so ArgoCD can recreate them:

```bash
# Delete StatefulSet and stuck PVC
ssh debian@10.30.0.10 "kubectl delete statefulset authentik-postgresql -n authentik"
ssh debian@10.30.0.10 "kubectl delete pvc data-authentik-postgresql-0 -n authentik"

# ArgoCD self-heals and recreates the StatefulSet without persistence
ssh debian@10.30.0.10 "kubectl get pods -n authentik -w"
```

**Note:** Like Loki, PostgreSQL with `persistence.enabled: false` uses emptyDir — all data is lost on pod deletion or node reboot. Deploy a StorageClass (local-path-provisioner or Longhorn) before running stateful services in production.

## Authentik: AUTHENTIK_BOOTSTRAP_TOKEN only works on first startup

The `AUTHENTIK_BOOTSTRAP_TOKEN` environment variable only creates an API token during the **initial database bootstrap** (first startup with empty database). If Authentik has already been started, adding the env var and restarting has no effect — the token won't be created.

**Fix:** Create the token via Django shell (`ak shell`) instead:

```bash
ssh debian@10.30.0.10 'kubectl exec -n authentik deployment/authentik-server -- ak shell -c "
from authentik.core.models import Token, TokenIntents, User
user = User.objects.get(username=\"akadmin\")
token, created = Token.objects.get_or_create(
    identifier=\"my-api-token\",
    defaults={
        \"user\": user,
        \"intent\": TokenIntents.INTENT_API,
        \"key\": \"your-token-value-here\",
        \"expiring\": False,
    }
)
print(f\"Token created: {created}, key: {token.key[:8]}...\")
"'
```

In Ansible, pipe via heredoc since `ak shell -c` has quoting issues over SSH:

```yaml
- name: Ensure API token exists in Authentik database
  become: false
  ansible.builtin.shell: |
    cat <<'PYEOF' | kubectl exec -i -n authentik deployment/authentik-server -- ak shell
    from authentik.core.models import Token, TokenIntents, User
    user = User.objects.get(username="akadmin")
    token, created = Token.objects.get_or_create(
        identifier="my-api-token",
        defaults={
            "user": user,
            "intent": TokenIntents.INTENT_API,
            "key": "{{ my_token_var }}",
            "expiring": False,
        }
    )
    print(f"Token created: {created}")
    PYEOF
  environment:
    KUBECONFIG: /home/debian/.kube/config
```

## Authentik API: invalidation_flow and redirect_uris format (2025.12+)

Authentik 2025.12 introduced **required** fields that weren't needed in earlier versions. API calls to create providers will fail with 400 errors if these are missing.

**`invalidation_flow` is required** for all provider types (proxy, OAuth2):

```json
{"invalidation_flow": ["This field is required."]}
```

**Fix:** Fetch the default invalidation flow and include it in all provider creation requests:

```bash
# Get the invalidation flow UUID
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:9000/api/v3/flows/instances/?designation=invalidation \
  | jq '.results[0].pk'
```

**`redirect_uris` must be a list of objects**, not strings:

```json
{"redirect_uris": {"non_field_errors": ["Expected a list of items but got type \"str\"."]}}
```

**Fix:** Each redirect URI needs `matching_mode` and `url` fields:

```yaml
# Wrong
redirect_uris: "https://grafana.example.com/login/generic_oauth"

# Also wrong
redirect_uris:
  - "https://grafana.example.com/login/generic_oauth"

# Correct
redirect_uris:
  - matching_mode: strict
    url: "https://grafana.example.com/login/generic_oauth"
```

## Ansible: background port-forward dies between tasks

Using `&` to background `kubectl port-forward` in an Ansible `shell` task doesn't work — the process gets killed when the SSH channel for that task closes.

```yaml
# Broken — port-forward dies after this task completes
- name: Start port-forward
  ansible.builtin.shell: >-
    kubectl port-forward svc/my-svc 9000:80 &
    echo $!
```

**Fix:** Use `nohup` and redirect output to a file:

```yaml
- name: Start port-forward
  become: false
  ansible.builtin.shell: >-
    nohup kubectl port-forward svc/my-svc 9000:80
    > /tmp/pf.log 2>&1 &
    echo $!
  register: pf_pid

- name: Wait for port-forward
  become: false
  ansible.builtin.wait_for:
    port: 9000
    host: 127.0.0.1
    timeout: 30

# ... do work ...

- name: Kill port-forward
  become: false
  ansible.builtin.command: "kill {{ pf_pid.stdout_lines[-1] }}"
  failed_when: false
```

## ArgoCD Helm chart: configs.rbac vs configs.rbacConfig

The argo-cd Helm chart uses `configs.rbac` for RBAC policy configuration. Using `configs.rbacConfig` (which appears in some older docs/examples) silently does nothing — the configmap gets default empty values.

```yaml
# Wrong — silently ignored
argo-cd:
  configs:
    rbacConfig:
      policy.default: role:readonly

# Correct
argo-cd:
  configs:
    rbac:
      policy.default: role:readonly
      policy.csv: |
        g, authentik Admins, role:admin
```

Verify the RBAC config was applied:

```bash
kubectl get configmap argocd-rbac-cm -n argocd -o jsonpath='{.data}'
```

## Authentik OAuth2: HS256 instead of RS256 signing

Authentik OAuth2 providers default to HS256 (symmetric) JWT signing when no `signing_key` is set, or when `signing_key` references a **non-existent certificate UUID**. OIDC clients that require RS256 (e.g. Headlamp) will fail with:

```
oidc: malformed jwt: go-jose/go-jose: unexpected signature algorithm "HS256"; expected ["RS256"]
```

This can happen when a certificate is lost (e.g. PostgreSQL data reset before persistence was enabled) — the provider still references the old UUID but the certificate no longer exists, so Authentik silently falls back to HS256.

**Fix:** Generate a new signing certificate and update all providers:

```bash
# Generate a new RSA keypair for JWT signing
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  http://localhost:9000/api/v3/crypto/certificatekeypairs/generate/ \
  -d '{"common_name": "authentik JWT Signing Key", "subject_alt_name": "authentik JWT Signing Key", "validity_days": 3650}' \
  | jq '.pk'

# Patch each OAuth2 provider with the new signing key UUID
curl -s -X PATCH -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  http://localhost:9000/api/v3/providers/oauth2/<provider-pk>/ \
  -d '{"signing_key": "<new-cert-uuid>"}'
```

In Ansible, the `authentik-config` role finds or creates the certificate by name (`authentik JWT Signing Key`) and includes `signing_key` in all OAuth2 provider creation requests.

## Client VPN: traffic not reaching homelab services

When a device connects to the VPS WireGuard VPN (split tunnel) but services like `home.ruddenchaux.xyz` time out, there are three independent issues that can all be triggered by the same root cause: **`wg syncconf` does not run PostUp hooks and does not add kernel routes**. The `vps-client-vpn` playbook uses `syncconf` to hot-reload the peer without dropping the MikroTik tunnel, but this means everything that PostUp would normally set up must be applied separately.

### Diagnosis

**Step 1 — check WireGuard peer status on the VPS**

```bash
ssh root@89.167.62.126 "wg show wg0"
```

Look for:
- `latest handshake` — if it's recent (< 3 minutes), the tunnel is up
- `transfer` — if the client peer shows only a few KB, only keepalives are flowing (no real traffic)

**Step 2 — capture traffic on the VPS while the client tries to connect**

```bash
# Install tcpdump if missing
ssh root@89.167.62.126 "apt-get install -y tcpdump -q"

# Capture 20 seconds of traffic from the client IP on all interfaces
# (run this, then immediately try the service on the client device)
ssh root@89.167.62.126 "timeout 20 tcpdump -i any -n 'udp port 51820 or host 10.100.0.10'"
```

Key patterns to look for:

| What you see | Meaning |
|---|---|
| No packets at all | Client isn't routing traffic through the VPN — DNS or routing issue on device |
| `wg0 In ... 10.100.0.10 > 10.30.0.200 [S]` then `eth0 Out ... 10.30.0.200 > 10.100.0.10 [S.]` | SYN arrives but SYN-ACK goes out eth0 (internet) instead of back through wg0 — **missing kernel route** |
| SYN arrives, no SYN-ACK at all | Forwarding is blocked — check iptables/UFW |

---

### Issue 1: iptables MASQUERADE rules not applied

**Symptom:** Client traffic arrives at VPS (`wg0 In 10.100.0.10 > 10.30.0.x`) but MikroTik has no route back to `10.100.0.10`. Return traffic is dropped.

**Root cause:** `wg syncconf` only updates WireGuard cryptographic state — it does not execute `PostUp`. The MASQUERADE rule (which rewrites Android's IP to `10.100.0.1` so MikroTik can route the reply) is defined in PostUp and was never applied.

**Verify:**

```bash
# Check if the MASQUERADE rule exists (counter should be > 0 after a connection attempt)
ssh root@89.167.62.126 "iptables -t nat -L POSTROUTING -n -v | grep MASQUERADE"
```

If the rule is missing or the counter stays at 0, apply it manually:

```bash
# Apply the three rules that PostUp would have set
ssh root@89.167.62.126 "iptables -t nat -A POSTROUTING -s 10.100.0.0/24 -j MASQUERADE"
# ^ rewrites client src IP to 10.100.0.1 so MikroTik can route replies back through the tunnel

ssh root@89.167.62.126 "iptables -A FORWARD -i wg0 -j ACCEPT"
# ^ allows forwarding of packets arriving on wg0 (client → homelab direction)

ssh root@89.167.62.126 "iptables -A FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
# ^ allows reply packets back out through wg0 (homelab → client direction, conntrack-tracked)
```

**Permanent fix:** re-running `ansible-playbook ansible/playbooks/vps-client-vpn.yml` now applies these as explicit Ansible tasks (not just PostUp), so they survive `syncconf` hot-reloads.

---

### Issue 2: UFW DEFAULT_FORWARD_POLICY=DROP blocking all forwarded traffic

**Symptom:** Client SYNs arrive at VPS but no SYN-ACK comes back at all. The MASQUERADE rule counter stays at 0 even though packets are arriving on wg0.

**Root cause:** Hetzner Debian VPS images come with UFW enabled. UFW's default `FORWARD` policy is `DROP`, and UFW chains run *before* any custom iptables rules. This silently drops all forwarded traffic regardless of any `iptables -A FORWARD` rules added manually.

**Verify:**

```bash
# Check UFW forward policy (should say "allow (routed)" after the fix)
ssh root@89.167.62.126 "ufw status verbose | grep routed"

# Check the raw setting
ssh root@89.167.62.126 "grep DEFAULT_FORWARD_POLICY /etc/default/ufw"

# Check the FORWARD chain — if policy is DROP and there are UFW chains, they run first
ssh root@89.167.62.126 "iptables -L FORWARD -n --line-numbers"
```

**Fix:**

```bash
# Change UFW forward policy to ACCEPT and reload
ssh root@89.167.62.126 "sed -i 's/DEFAULT_FORWARD_POLICY=\"DROP\"/DEFAULT_FORWARD_POLICY=\"ACCEPT\"/' /etc/default/ufw && ufw reload"
```

**Why ACCEPT is safe here:** The VPS routing table only contains routes to homelab IPs (`10.30.0.0/24`, `10.100.0.x`) via `wg0`. For any internet traffic to reach the homelab it would need to be forwarded out `wg0`, which WireGuard rejects for any peer not holding a valid private key. The security boundary is WireGuard's cryptographic authentication, not iptables FORWARD rules.

**Permanent fix:** re-running `ansible-playbook ansible/playbooks/vps-client-vpn.yml` now sets this in `ip_forward.yml` as part of the role.

---

### Issue 3: missing kernel route for client IP

**Symptom:** SYN arrives on `wg0`, SYN-ACK is visible in tcpdump but exits on `eth0` (the internet interface) instead of `wg0`. The TCP handshake never completes and the browser times out.

**Root cause:** `wg-quick` adds kernel routes for each peer's `AllowedIPs` when the interface is started. `wg syncconf` updates the peer list but does **not** add kernel routes. So the VPS has the peer in WireGuard (`wg show wg0` shows the client) but the kernel routing table has no entry for `10.100.0.10`. After conntrack un-masquerades the reply (destination reverts from `10.100.0.1` back to `10.100.0.10`), the kernel falls back to the default route and sends the packet out via `eth0`.

**Verify:**

```bash
# Check routing table — should have a /32 entry for the client IP via wg0
ssh root@89.167.62.126 "ip route show | grep 10.100.0"

# Expected output:
#   10.100.0.0/30 dev wg0 proto kernel scope link src 10.100.0.1
#   10.100.0.10   dev wg0 scope link    ← this line is what syncconf doesn't add
```

**Fix:**

```bash
# Add the missing route (replace is idempotent — safe to run multiple times)
ssh root@89.167.62.126 "ip route replace 10.100.0.10/32 dev wg0"
# ^ tells the kernel: packets destined for 10.100.0.10 exit via the wg0 interface,
#   which then encrypts and sends them to the Android WireGuard peer
```

**Permanent fix:** re-running `ansible-playbook ansible/playbooks/vps-client-vpn.yml` now runs `ip route replace` as an explicit task after `syncconf`.

---

### Full recovery (all three issues at once)

If starting from a broken state (client VPN was set up via `vps-client-vpn.yml` but services are unreachable):

```bash
# 1. Apply iptables rules
ssh root@89.167.62.126 "iptables -t nat -A POSTROUTING -s 10.100.0.0/24 -j MASQUERADE"
ssh root@89.167.62.126 "iptables -A FORWARD -i wg0 -j ACCEPT"
ssh root@89.167.62.126 "iptables -A FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"

# 2. Fix UFW forward policy
ssh root@89.167.62.126 "sed -i 's/DEFAULT_FORWARD_POLICY=\"DROP\"/DEFAULT_FORWARD_POLICY=\"ACCEPT\"/' /etc/default/ufw && ufw reload"

# 3. Add kernel route for client
ssh root@89.167.62.126 "ip route replace 10.100.0.10/32 dev wg0"

# Verify end-to-end: VPS should be able to curl a homelab service
ssh root@89.167.62.126 "curl -sk -o /dev/null -w '%{http_code}' https://home.ruddenchaux.xyz"
# Expected: 302 (Authentik ForwardAuth redirect = Traefik is working)
```

These fixes are now permanent in the Ansible role — re-running `vps-client-vpn.yml` applies all three automatically.

## Home Assistant: "New automation setup timed out"

**Symptom:** Every automation saved via the HA UI shows "New automation setup timed out. Your new automation was saved, but waiting for it to set up has timed out." Automations are written to `automations.yaml` but never appear in the UI. Zero `automation.*` entities ever created (confirmed via DB query).

**Root cause:** `default_config:` in HA 2025.12 no longer includes `automation` as a dependency (verified via `/usr/src/homeassistant/homeassistant/components/default_config/manifest.json`). Without an explicit `automation:` entry in `configuration.yaml`, the automation component is never initialized and `automations.yaml` is never read.

**Fix:** Add to `configuration.yaml`:

```yaml
automation: !include automations.yaml
```

**Diagnosis commands:**

```bash
# Check if automation entities have ever been created
ssh debian@10.30.0.10 "kubectl exec -n home-assistant deployment/home-assistant -- python3 -c \"
import sqlite3
conn = sqlite3.connect('/config/home-assistant_v2.db')
cur = conn.cursor()
cur.execute(\\\"SELECT COUNT(*) FROM states_meta WHERE entity_id LIKE 'automation.%'\\\")
print('automation entities ever:', cur.fetchone()[0])
\""

# Confirm automation is absent from default_config dependencies
ssh debian@10.30.0.10 "kubectl exec -n home-assistant deployment/home-assistant -- \
  grep automation /usr/src/homeassistant/homeassistant/components/default_config/manifest.json"
# Expected: no output — automation is not there
```

---

## Home Assistant: automation reload fails after MQTT entity config removal

**Symptom:** After removing an explicit `mqtt: climate:` block from `configuration.yaml` and restarting HA, adding new automations times out or existing ones stop working.

**Root cause:** Removing the explicit MQTT climate config and switching to auto-discovery (e.g. WThermostatBeca) creates a **new** device with a different `device_id` UUID. The old device is gone from the device registry. Automations with device-based actions (`type: set_hvac_mode`, `device_id: <old-uuid>`) reference a non-existent device, causing automation reload to fail silently.

**Fix:** Remove the broken automations from `automations.yaml` (they reference a dead `device_id`), reload, then recreate them via the UI pointing to the new entity.

```bash
# Find current devices and their IDs
ssh debian@10.30.0.10 "kubectl exec -n home-assistant deployment/home-assistant -- python3 -c \"
import json
data = json.load(open('/config/.storage/core.device_registry'))
for d in data['data']['devices']:
    print(d['id'], d.get('name',''), d.get('manufacturer',''))
\""

# Find climate entity IDs for the new device
ssh debian@10.30.0.10 "kubectl exec -n home-assistant deployment/home-assistant -- python3 -c \"
import json
data = json.load(open('/config/.storage/core.entity_registry'))
for e in data['data']['entities']:
    if 'climate' in e.get('entity_id',''):
        print(e['entity_id'], 'uuid:', e['id'], 'device:', e.get('device_id',''))
\""
```

---

## Grafana: ArgoCD continuous sync loop + stuck rolling update

Two independent bugs that became visible together on 2026-03-12.

### Bug 1 — Stuck rolling update (Degraded health)

**Symptom:** Grafana deployment has `ProgressDeadlineExceeded`. Many evicted pods from a stalled replicaset. New pods stuck in `Init:CrashLoopBackOff`.

**Root cause:** Grafana creates `csv`, `pdf`, `png` directories at startup with `drwx------` (mode 700). The `init-chown-data` init container drops ALL capabilities and only adds `CHOWN` — without `DAC_OVERRIDE`, it cannot traverse those 700 dirs even as UID 0, giving `Permission denied`. This only manifests on a rolling update while an old pod is running (dirs already exist). First deployment never hits it.

**Triggered by:** `kubectl rollout restart` on 2026-03-10, which created a new replicaset that could not start.

**Fix:**

```bash
# 1. Unblock the stuck rollout by fixing permissions on the running pod
ssh debian@10.30.0.10 "kubectl exec -n monitoring monitoring-grafana-<old-rs>-<hash> -c grafana -- \
  chmod 755 /var/lib/grafana/csv /var/lib/grafana/pdf /var/lib/grafana/png"

# 2. Delete the stuck pods so they restart with correct permissions
ssh debian@10.30.0.10 "kubectl get pods -n monitoring --field-selector=status.phase=Failed -o name \
  | xargs kubectl delete -n monitoring"
```

**Permanent fix:** Add `DAC_OVERRIDE` to the init container in `kubernetes/platform/monitoring/values.yaml`:

```yaml
kube-prometheus-stack:
  grafana:
    initChownData:
      securityContext:
        capabilities:
          add:
            - CHOWN
            - DAC_OVERRIDE
          drop:
            - ALL
        runAsNonRoot: false
        runAsUser: 0
```

---

### Bug 2 — Continuous ArgoCD sync loop (133 rolling update revisions)

**Symptom:** The monitoring ArgoCD app is always `OutOfSync`. `kubectl rollout history deployment/monitoring-grafana -n monitoring` shows 100+ revisions. ArgoCD admission webhook jobs (`monitoring-kube-prometheus-admission-create/patch`) are created and deleted every few minutes.

**Root cause (chain of three issues):**

1. **Random Grafana admin password** — the Grafana Helm chart generates a random `adminPassword` via `randAlphaNum 40` on every `helm template` render when no fixed password is set. ArgoCD renders the chart every ~3 minutes (refresh interval). Each render produces a new password → `monitoring-grafana` Secret is OutOfSync → sync → new `checksum/secret` annotation on Deployment → Deployment is OutOfSync → repeat forever.

2. **`restartedAt` annotation** — a `kubectl rollout restart` adds `kubectl.kubernetes.io/restartedAt` to the pod template, owned by the `argocd-server` SSA field manager. ArgoCD's controller (`argocd-controller`) cannot remove a field owned by another manager, so the Deployment remains permanently OutOfSync.

3. **Admission webhook pre-sync jobs stuck** — the prometheus-operator admission patch jobs (`batch/Job/monitoring-kube-prometheus-admission-*`) have `ttlSecondsAfterFinished: 60`. Kubernetes TTL controller deletes them 60s after completion, before ArgoCD can issue its own delete (as required by `hook-delete-policy: hook-succeeded`). ArgoCD's sync gets stuck "waiting for deletion" of a resource that no longer exists. The sync never reaches the main apply/prune phase.

**Fix:**

```bash
# Step 1 — create a stable admin credentials secret with the current password
CURRENT_PW=$(ssh debian@10.30.0.10 "kubectl get secret monitoring-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d")
ssh debian@10.30.0.10 "kubectl create secret generic grafana-admin-creds -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=$CURRENT_PW \
  --dry-run=client -o yaml | kubectl apply -f -"

# Step 2 — remove the stale restartedAt annotation
ssh debian@10.30.0.10 "kubectl patch deployment monitoring-grafana -n monitoring \
  --type=json -p '[{\"op\":\"remove\",\"path\":\"/spec/template/metadata/annotations/kubectl.kubernetes.io~1restartedAt\"}]'"

# Step 3 — delete the orphaned monitoring-grafana secret (will not be recreated after fix)
ssh debian@10.30.0.10 "kubectl delete secret monitoring-grafana -n monitoring"
```

Add to `kubernetes/platform/monitoring/values.yaml`:

```yaml
kube-prometheus-stack:
  grafana:
    admin:
      existingSecret: grafana-admin-creds  # stops random password generation
      userKey: admin-user
      passwordKey: admin-password
  prometheusOperator:
    admissionWebhooks:
      certManager:
        enabled: true  # replaces patch jobs with cert-manager Certificate resources
                       # eliminates pre-sync hooks that caused the stuck sync loop
```

**Why it only became visible:** The sync loop was running since day 1 (proving it: 133 deployment revisions over 24 days). But rolling updates completed in ~30s and Grafana remained Healthy, so nothing appeared broken. The stuck rolling update (Bug 1) caused a `Degraded` health status, which drew attention to the monitoring namespace, revealing the loop.

```bash
# Diagnose a continuous sync loop
ssh debian@10.30.0.10 "kubectl rollout history deployment/monitoring-grafana -n monitoring"
# Large revision count (> 10) with no intentional changes = sync loop

ssh debian@10.30.0.10 "kubectl get application monitoring -n argocd \
  -o jsonpath='{.status.operationState.message}'"
# "waiting for deletion of batch/Job/..." = stuck admission webhook hook

# Check who owns a deployment annotation (SSA field manager)
ssh debian@10.30.0.10 "kubectl get deployment monitoring-grafana -n monitoring \
  -o jsonpath='{.metadata.managedFields[*].manager}'"
```

---

### Bug 2 follow-up — stale hook RBAC resources block sync after certManager migration

**Symptom:** After committing `certManager.enabled: true`, the sync loop persists. ArgoCD message changes to `waiting for deletion of /ServiceAccount/monitoring-kube-prometheus-admission and 4 more hooks`. A new sync immediately recreates them. The pattern repeats indefinitely.

**Root cause:** The old job-patch hook resources (ServiceAccount + ClusterRole + ClusterRoleBinding + Role + RoleBinding) have `helm.sh/hook` annotations and remain in the cluster after switching to certManager mode. Unlike the Jobs (which have `ttlSecondsAfterFinished: 60` and self-delete), the RBAC resources have no auto-delete mechanism. ArgoCD treats them as active hooks and gets stuck "waiting for deletion". When the sync restarts, it sees them missing from the desired state and tries to prune them again — loop continues.

**Fix:** Delete the 5 stale hook resources manually once. ArgoCD can then complete the transition:

```bash
# Delete stale admission webhook hook resources
ssh debian@10.30.0.10 "kubectl delete serviceaccount monitoring-kube-prometheus-admission -n monitoring --ignore-not-found"
ssh debian@10.30.0.10 "kubectl delete clusterrole monitoring-kube-prometheus-admission --ignore-not-found"
ssh debian@10.30.0.10 "kubectl delete clusterrolebinding monitoring-kube-prometheus-admission --ignore-not-found"
ssh debian@10.30.0.10 "kubectl delete role monitoring-kube-prometheus-admission -n monitoring --ignore-not-found"
ssh debian@10.30.0.10 "kubectl delete rolebinding monitoring-kube-prometheus-admission -n monitoring --ignore-not-found"

# Verify ArgoCD completes the sync and creates cert-manager resources
ssh debian@10.30.0.10 "kubectl get certificates,issuers -n monitoring"
# Should show: monitoring-kube-prometheus-admission, monitoring-kube-prometheus-root-cert, 2 issuers

# Confirm no more admission jobs are being created
ssh debian@10.30.0.10 "kubectl get jobs -n monitoring"
# Expected: No resources found
```

After deletion, ArgoCD creates the cert-manager Issuers and Certificates and reaches `Synced Healthy` permanently.

---

## Lost SSH access to k8s VMs (pubkey was on another machine)

When the laptop that originally ran `terraform apply` is unavailable, its SSH pubkey is the only one in `/home/debian/.ssh/authorized_keys` on the k8s VMs. Cloud-init's `users` module only runs on first boot, so re-running Terraform won't propagate a new key to already-running VMs.

**Fix:** use `qm guest exec` from the Proxmox host — the VMs have `qemu-guest-agent` installed (baked into the template), which gives the Proxmox host a root-level command channel into each VM without needing SSH at all.

```bash
# 1. On the laptop you want to regain access from — get the pubkey
cat ~/.ssh/id_ed25519.pub
# (generate one first if missing: ssh-keygen -t ed25519)

# 2. SSH to Proxmox (root access is still via password or separate key)
ssh root@10.10.0.2

# 3. On pve01 — export the pubkey to avoid quoting headaches
PUBKEY='ssh-ed25519 AAAA...PASTE_WHOLE_LINE... user@host'

# 4. Sanity check the guest agent channel works
qm guest exec 200 -- bash -c 'whoami && hostname'
# Expected: {"exitcode": 0, "out-data": "root\nk8s-ctrl-01\n"}

# 5. Push the key into every k8s VM (200 = ctrl, 201-203 = workers)
for vmid in 200 201 202 203; do
  qm guest exec $vmid --timeout 10 -- bash -c "mkdir -p /home/debian/.ssh && echo '$PUBKEY' >> /home/debian/.ssh/authorized_keys && chown -R debian:debian /home/debian/.ssh && chmod 700 /home/debian/.ssh && chmod 600 /home/debian/.ssh/authorized_keys && echo OK"
done
# Expected per VM: {"exitcode": 0, "out-data": "OK\n"}

# 6. Verify from the laptop
ssh debian@10.30.0.10 'hostname'
```

**Quoting notes** (the part that bites):
- **Outer `"..."` around `bash -c`** — so pve01 expands `$PUBKEY` from your shell variable.
- **Inner `'...'` around `$PUBKEY`** in the `echo` — so the key bytes land in `authorized_keys` verbatim, even with spaces and `+`/`=` characters.
- `qm guest exec ... -- bash -c '<script>'` — the `--` separates `qm` flags from the command that runs inside the VM.

**After regaining access:** copy `/etc/kubernetes/admin.conf` from the control plane to your laptop's `~/.kube/config`, then consider committing a SOPS-encrypted copy to the repo so a future laptop doesn't hit the same problem:

```bash
ssh debian@10.30.0.10 'sudo cat /etc/kubernetes/admin.conf' > ~/.kube/config
chmod 600 ~/.kube/config
```

**Why not `terraform apply`:** the `user_account.keys` field only writes to the cloud-init datasource image. Cloud-init's `users` module runs once per-instance (tracked in `/var/lib/cloud/instances/<id>/sem/`), so the new key is present on the cloud-init drive but never copied into `authorized_keys` on the live VM.

---

## General cluster health

```bash
# Node status
ssh debian@10.30.0.10 "kubectl get nodes -o wide"

# All pods across namespaces
ssh debian@10.30.0.10 "kubectl get pods -A"

# Cilium status (run from any Cilium agent pod)
ssh debian@10.30.0.10 "kubectl -n kube-system exec ds/cilium -- cilium-dbg status"

# Cilium L2 announcements and IP pool
ssh debian@10.30.0.10 "kubectl get ciliumloadbalancerippool"
ssh debian@10.30.0.10 "kubectl get ciliuml2announcementpolicy"
ssh debian@10.30.0.10 "kubectl get leases -n kube-system | grep l2"
```
