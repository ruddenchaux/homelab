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
