# Homelab

Infrastructure as Code for a single-node Proxmox homelab running Kubernetes (k8s).

## Hardware

- **Server**: Dell R740xd 2U 12LFF
- **CPU**: 2x Intel Xeon Gold 6140 (36C/72T total)
- **RAM**: 96GB DDR4
- **Boot**: 2x 960GB SAS SSD (ZFS mirror)
- **Data**: 2x 4TB SAS HDD (ZFS mirror)
- **NIC**: 2x 10G + 2x 1G

## Stack

| Layer | Tool |
|-------|------|
| Host config | Ansible |
| VM templates | Packer |
| VM provisioning | Terraform (bpg/proxmox) |
| First boot | cloud-init |
| Cluster | Kubernetes |
| GitOps | ArgoCD + Helm |
| Secrets | SOPS + age |

## Project Structure

```
ansible/
  requirements.yml              # Collection dependencies (community.routeros, ansible.netcommon, kubernetes.core)
  inventory/
    hosts.yml                   # Proxmox + MikroTik + k8s hosts
    group_vars/
      mikrotik.yml              # RouterOS connection settings
      k8s.yml                   # Kubernetes nodes connection settings
  playbooks/
    proxmox-base.yml            # Base Proxmox configuration
    network-vlans.yml           # VLAN setup on MikroTik + Proxmox
    kubernetes-install.yml      # Kubernetes cluster install (kubeadm + Cilium)
    argocd-bootstrap.yml        # ArgoCD + Traefik + cert-manager bootstrap
  roles/
    proxmox-repos/              # Disable enterprise, enable no-subscription repos
    system-upgrade/             # apt upgrade + reboot if needed
    zfs-datapool/               # Create ZFS mirror on data HDDs
    ssh-hardening/              # Key-only auth, disable root password login
    mikrotik-guest-cleanup/     # Remove leftover guest WiFi experiment
    mikrotik-vlans/             # Bridge VLAN table, VLAN interfaces, firewall
    proxmox-networking/         # VLAN-aware bridge, management IP, DNS
    k8s-prerequisites/          # Containerd, kubeadm, kubelet, kernel modules
    k8s-control-plane/          # kubeadm init, Helm, Cilium CNI
    k8s-workers/                # kubeadm join workers to cluster
    cilium-l2/                  # Cilium L2 announcements for LoadBalancer
    argocd/                     # ArgoCD install + GitOps bootstrap
packer/
  debian-13/
    debian-13.pkr.hcl           # Packer template (proxmox-iso builder)
    variables.pkr.hcl           # Variable definitions with defaults
    debian-13.auto.pkrvars.hcl  # User secrets (GITIGNORED)
    http/
      preseed.cfg               # Debian automated install preseed
    scripts/
      cleanup.sh                # Template sysprep (cloud-init reset, cleanup)
terraform/
  kubernetes/
    versions.tf                 # Terraform + provider version constraints
    variables.tf                # Variable definitions with defaults
    main.tf                     # Provider config + VM resources
    outputs.tf                  # VM IP outputs
    terraform.auto.tfvars       # API token secret (GITIGNORED)
kubernetes/
  apps/                             # Root app-of-apps (ArgoCD Application set)
    Chart.yaml
    values.yaml
    templates/                      # ArgoCD Application manifests
  platform/
    argocd/                         # ArgoCD self-managed umbrella chart
    traefik/                        # Traefik ingress umbrella chart
    cert-manager/                   # cert-manager + ClusterIssuers
```

## Network

| VLAN | Name | Subnet | Gateway |
|------|------|--------|---------|
| 1 | Default | 192.168.88.0/24 | 192.168.88.1 |
| 10 | Management | 10.10.0.0/24 | 10.10.0.1 |
| 20 | Trusted LAN | 10.20.0.0/24 | 10.20.0.1 |
| 30 | Kubernetes | 10.30.0.0/24 | 10.30.0.1 |

## Prerequisites

These one-time manual steps are required before running automation:

```bash
# 1. Import SSH public key into MikroTik (for VLAN playbook)
#    Upload key via MikroTik WebFig or WinBox, then:
#    /user/ssh-keys/import public-key-file=id_ed25519.pub user=admin

# 2. Create Proxmox API token for Packer
ssh root@10.10.0.2 "pveum user token add root@pam packer-token --privsep 0"
# Save the displayed token secret

# 3. Create Packer secrets file
cat > packer/debian-13/debian-13.auto.pkrvars.hcl <<'EOF'
proxmox_token_secret = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
http_ip              = "192.168.88.254"
EOF

# 4. Initialize Packer plugins
cd packer/debian-13 && packer init .

# 5. Create Terraform secrets file
cat > terraform/kubernetes/terraform.auto.tfvars <<'EOF'
proxmox_api_token = "root@pam!packer-token=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
EOF

# 6. Create Cloudflare API token for cert-manager DNS-01 challenge
#    Go to Cloudflare dashboard → My Profile → API Tokens → Create Token
#    Use "Edit zone DNS" template, scope to your zone
```

## Usage

```bash
# Install Python dependency for MikroTik network_cli connection
pip install paramiko

# Install Ansible collection dependencies
ansible-galaxy collection install -r ansible/requirements.yml

# Configure Proxmox base (repos, ZFS, SSH hardening)
ansible-playbook ansible/playbooks/proxmox-base.yml

# Configure VLANs on MikroTik and Proxmox
ansible-playbook ansible/playbooks/network-vlans.yml

# Build Packer VM template
cd packer/debian-13 && packer build .

# Provision Kubernetes VMs with Terraform
cd terraform/kubernetes && terraform init
terraform plan
terraform apply

# Install Kubernetes cluster (kubeadm + Cilium)
ansible-playbook ansible/playbooks/kubernetes-install.yml

# Verify cluster
ssh debian@10.30.0.10 "kubectl get nodes -o wide"
ssh debian@10.30.0.10 "kubectl get pods -n kube-system"

# Bootstrap ArgoCD and GitOps platform (Cilium L2 + ArgoCD + Traefik + cert-manager)
ansible-playbook ansible/playbooks/argocd-bootstrap.yml \
  --extra-vars "gitops_repo_url=https://github.com/<user>/homelab.git" \
  --extra-vars "cloudflare_api_token=<token>" \
  --extra-vars "acme_email=<email>"

# Get ArgoCD initial admin password
ssh debian@10.30.0.10 "kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo"

# Access ArgoCD UI via port-forward
ssh -L 8080:localhost:8080 debian@10.30.0.10 \
  "kubectl port-forward svc/argocd-server -n argocd 8080:443"
# Then open https://localhost:8080 (user: admin)

# Verify Cilium L2 load balancing
ssh debian@10.30.0.10 "kubectl get ciliumloadbalancerippool"
ssh debian@10.30.0.10 "kubectl get ciliuml2announcementpolicy"

# Verify ArgoCD applications
ssh debian@10.30.0.10 "kubectl get applications -n argocd"

# Verify Traefik (should have external IP from 10.30.0.200-250)
ssh debian@10.30.0.10 "kubectl get svc -n traefik"

# Verify cert-manager and ClusterIssuers
ssh debian@10.30.0.10 "kubectl get pods -n cert-manager"
ssh debian@10.30.0.10 "kubectl get clusterissuer"
```

## Troubleshooting

### Cilium L2 LoadBalancer IPs unreachable

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

### ArgoCD application stuck on Unknown/OutOfSync

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

### TLS certificate not issued

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

### Traefik not routing traffic

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

### General cluster health

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

## Roadmap

1. ~~Proxmox base configuration~~ (done)
2. ~~Network VLANs (Proxmox + MikroTik)~~ (done)
3. ~~Packer VM template (Debian 13)~~ (done)
4. ~~Terraform VM provisioning~~ (done)
5. ~~Kubernetes cluster install~~ (done)
6. ~~ArgoCD + GitOps platform~~ (done)
7. Service deployment
