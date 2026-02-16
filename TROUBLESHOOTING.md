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
