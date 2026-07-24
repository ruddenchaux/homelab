# Homelab

Infrastructure as Code for a Proxmox homelab running Kubernetes (k8s).

## Architecture: two sites, hub-and-spoke

The lab is moving from a single home site to two sites:

- **Bottega** (workspace): static public IP, becomes the **hub** — terminates
  WireGuard, is the DNS/ingress entry point, the only site reachable from the
  internet. The server and cluster described below live here.
- **Casa** (home): Starlink CGNAT, becomes a **spoke** — dials out to Bottega,
  cannot accept inbound connections directly. Its LAN must be reachable from
  Bottega and administrable from Bottega.
- A road-warrior WireGuard peer (phone) administers both sites from outside.

The Hetzner VPS relay that previously worked around Casa's CGNAT is being
decommissioned now that Bottega has its own static IP — see
[`MIGRATION.md`](MIGRATION.md) for the obsolete-component list and safe
removal order, and [`specs/network/topology.md`](specs/network/topology.md)
for the full rationale and addressing plan.

## Spec-driven workflow

Network and site design decisions live in [`specs/`](specs/README.md) as the
single source of truth, written **before** the Ansible/Terraform/Kubernetes
change that implements them:

```
specs/            ← intent: what should be true, and why (this repo's SoT)
  network/          topology, wireguard peers, firewall, dns-exposure
  sites/             bottega.md, casa.md
  services/          per-service exposure spec template
        │
        ▼ implemented by
ansible/, terraform/, packer/, kubernetes/   ← unchanged by this workflow
```

Rules that apply to every change — regardless of which site or layer — live in
[`AGENTS.md`](AGENTS.md) (secrets separation per site, non-overlapping
subnets, WireGuard peer symmetry, MikroTik safe-mode, router management never
on WAN). `CLAUDE.md` points to `AGENTS.md` rather than duplicating it.

`.claude/` holds the supporting context-engineering layers:
- `skills/` — step-by-step procedures an agent loads on demand (adding a
  road-warrior peer, exposing a service, making a safe MikroTik change).
- `commands/` — explicitly invoked (`/plan-change`, `/review-net-diff`).
- `agents/` — scoped personas (`network-planner` is read-only and proposes
  plans against `specs/`; `implementer` applies an already-approved plan).

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
    proxmox-metrics.yml         # Proxmox datacenter metrics → InfluxDB
    ha-config.yml               # Home Assistant: Authentik OIDC + first-boot onboarding (pre/post-deploy tags)
    vps-relay.yml               # Hetzner VPS relay: WireGuard tunnel + nginx TCP passthrough
    vps-client-vpn.yml          # Client VPN: road warrior WireGuard peer + QR code
    worker-data-disk.yml        # Format + mount 500GB HDD data disk on k8s workers
  roles/
    proxmox-repos/              # Disable enterprise, enable no-subscription repos
    system-upgrade/             # apt upgrade + reboot if needed
    zfs-datapool/               # Create ZFS mirror on data HDDs
    proxmox-storage/            # Register ZFS datapool as Proxmox storage backend
    ssh-hardening/              # Key-only auth, disable root password login
    mikrotik-guest-cleanup/     # Remove leftover guest WiFi experiment
    mikrotik-vlans/             # Bridge VLAN table, VLAN interfaces, firewall
    mikrotik-wireguard/         # MikroTik WireGuard tunnel peer for VPS relay
    proxmox-networking/         # VLAN-aware bridge, management IP, DNS
    k8s-prerequisites/          # Containerd, kubeadm, kubelet, kernel modules
    k8s-control-plane/          # kubeadm init, Helm, Cilium CNI
    k8s-workers/                # kubeadm join workers to cluster
    worker-data-disk/           # ext4 format + mount /data/local-path-provisioner on workers
    cilium-l2/                  # Cilium L2 announcements + Hubble UI for LoadBalancer
    authentik-secrets/          # Pre-create Authentik k8s secrets
    authentik-config/           # Configure Authentik via REST API (OIDC providers, ForwardAuth)
    influxdb-secrets/           # Pre-create InfluxDB k8s secret (auto-generated token)
    proxmox-influxdb-metrics/   # Configure Proxmox datacenter metric server
    media-secrets/              # Pre-create NordVPN + media API keys k8s secrets
    media-config/               # Configure media services via REST APIs + port-forwards
    immich-secrets/             # Pre-create Immich admin credentials k8s secret
    immich-init/                # Immich first-time admin setup + Authentik OIDC via REST API
    ha-config/                  # Authentik OIDC setup + HA first-boot onboarding via REST API
    vps-relay/                  # VPS nginx stream proxy + WireGuard config
    vps-client-vpn/             # Client VPN peer generation + wg syncconf hot-reload
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
    hubble-ui/                      # Hubble UI ingress + certificate
    monitoring/                     # kube-prometheus-stack (Prometheus + Grafana)
    loki/                           # Loki log aggregation
    influxdb/                       # InfluxDB 2 time-series database
    kubernetes-dashboard/           # Headlamp Kubernetes dashboard
    authentik/                      # Authentik SSO
    homepage/                       # Homepage app launcher
    home-assistant/                 # Home Assistant (hass-openid + HACS via init containers, OIDC, MQTT)
    immich/                         # Immich photo library (server + ML + Valkey + PostgreSQL)
    media/                          # Servarr media stack (Radarr, Sonarr, Lidarr, Readarr, Prowlarr,
                                    #   Bazarr, qBittorrent+Gluetun VPN, NZBGet, Jellyfin, Seerr,
                                    #   FlareSolverr, Recyclarr CronJob)
    coredns/                        # CoreDNS ConfigMap override (forward ruddenchaux.xyz → AdGuardHome)
    metrics-server/                 # Kubernetes metrics-server
```

## Network

| VLAN | Name | Subnet | Gateway |
|------|------|--------|---------|
| 1 | Default | 192.168.88.0/24 | 192.168.88.1 |
| 10 | Management | 10.10.0.0/24 | 10.10.0.1 |
| 20 | Trusted LAN | 10.20.0.0/24 | 10.20.0.1 |
| 30 | Kubernetes | 10.30.0.0/24 | 10.30.0.1 |

## Services

| URL | Service | Purpose |
|-----|---------|---------|
| `https://home.ruddenchaux.xyz` | Homepage | App launcher |
| `https://grafana.ruddenchaux.xyz` | Grafana | Metrics, logs, dashboards |
| `https://influxdb.ruddenchaux.xyz` | InfluxDB 2 | Time-series metrics (Proxmox) |
| `https://hubble.ruddenchaux.xyz` | Hubble UI | Cilium network flows |
| `https://dashboard.ruddenchaux.xyz` | Headlamp | Cluster management |
| `https://auth.ruddenchaux.xyz` | Authentik | SSO / identity provider |
| `https://argocd.ruddenchaux.xyz` | ArgoCD | GitOps deployment |
| `https://traefik.ruddenchaux.xyz` | Traefik | Ingress routing |
| `https://ha.ruddenchaux.xyz` | Home Assistant | Home automation |
| `https://haconfig.ruddenchaux.xyz` | code-server (VS Code) | Home Assistant config editor |
| `https://immich.ruddenchaux.xyz` | Immich | Photo library & backup |
| `https://radarr.ruddenchaux.xyz` | Radarr | Movie management |
| `https://sonarr.ruddenchaux.xyz` | Sonarr | TV show management |
| `https://lidarr.ruddenchaux.xyz` | Lidarr | Music management |
| `https://readarr.ruddenchaux.xyz` | Readarr | Book management |
| `https://prowlarr.ruddenchaux.xyz` | Prowlarr | Indexer manager |
| `https://bazarr.ruddenchaux.xyz` | Bazarr | Subtitle management |
| `https://qbittorrent.ruddenchaux.xyz` | qBittorrent | Torrent client (NordVPN WireGuard) |
| `https://nzbget.ruddenchaux.xyz` | NZBGet | Usenet downloader |
| `https://jellyfin.ruddenchaux.xyz` | Jellyfin | Media server (also public via VPS relay) |
| `https://seerr.ruddenchaux.xyz` | Seerr | Media requests |
| `https://loki.ruddenchaux.xyz` | Loki | Log aggregation (internal, allowlist-protected) |
| `https://paperless.ruddenchaux.xyz` | Paperless-ngx | Document management & OCR |

Internal-only (no ingress): Prometheus, FlareSolverr, Recyclarr (CronJob).

Internal services resolve via AdGuardHome wildcard (`*.ruddenchaux.xyz → 10.30.0.200`), no Cloudflare DNS record needed.
Jellyfin has a real Cloudflare A record → VPS IP (`89.167.62.126`) for public internet access via WireGuard relay.

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

# Verify monitoring stack (Prometheus + Grafana)
ssh debian@10.30.0.10 "kubectl get pods -n monitoring"

# Verify Loki
ssh debian@10.30.0.10 "kubectl get pods -n loki"

# Verify Hubble UI
ssh debian@10.30.0.10 "kubectl get pods -n kube-system | grep hubble"

# Verify Headlamp (Kubernetes dashboard)
ssh debian@10.30.0.10 "kubectl get pods -n kubernetes-dashboard"

# Verify Homepage
ssh debian@10.30.0.10 "kubectl get pods -n homepage"

# Verify Authentik
ssh debian@10.30.0.10 "kubectl get pods -n authentik"
ssh debian@10.30.0.10 "kubectl get middleware -n authentik"
# Initial admin setup: https://auth.ruddenchaux.xyz/if/flow/initial-setup/

# Configure Proxmox datacenter metrics → InfluxDB (creates 'proxmox' bucket + metric server)
ansible-playbook ansible/playbooks/proxmox-metrics.yml
# Verify in Proxmox UI: Datacenter → Metric Server

# Deploy media stack (Servarr): pre-create NordVPN secret, let ArgoCD sync, then configure services
# Step 1: pre-create NordVPN + media secrets in k8s
ansible-playbook ansible/playbooks/argocd-bootstrap.yml --tags media-secrets
# Step 2: push to git and let ArgoCD sync kubernetes/platform/media/
# Step 3: configure inter-service connections via REST APIs
ansible-playbook ansible/playbooks/argocd-bootstrap.yml --tags media-config

# Deploy Immich (photo library)
# Immich setup is handled by immich-secrets + immich-init roles (run as part of argocd-bootstrap.yml)
# immich-init creates the admin account + configures Authentik OIDC via REST API

# Deploy Home Assistant
# Step 1: pre-deploy — creates Authentik OIDC provider + ha-oidc-secret in k8s
ansible-playbook ansible/playbooks/ha-config.yml --tags pre-deploy
# Step 2: push to git and let ArgoCD sync the Home Assistant Helm chart
# Step 3: post-deploy — waits for HA to be ready, completes first-boot onboarding via REST API
ansible-playbook ansible/playbooks/ha-config.yml --tags post-deploy

# Set up VPS relay for public internet access (Jellyfin + any future public service)
# Requires Hetzner VPS already provisioned and added to ansible/inventory/hosts.yml
ansible-playbook ansible/playbooks/vps-relay.yml
# If you later add client VPN peers (road warrior), restore them after re-running vps-relay.yml:
ansible-playbook ansible/playbooks/vps-client-vpn.yml
# Add a new device: -e vpn_client_name=laptop -e vpn_client_ip=10.100.0.11
```

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues and debugging commands.

## Roadmap

1. ~~Proxmox base configuration~~ (done)
2. ~~Network VLANs (Proxmox + MikroTik)~~ (done)
3. ~~Packer VM template (Debian 13)~~ (done)
4. ~~Terraform VM provisioning~~ (done)
5. ~~Kubernetes cluster install~~ (done)
6. ~~ArgoCD + GitOps platform~~ (done)
7. ~~Monitoring & dashboards (Prometheus + Grafana + Loki + InfluxDB)~~ (done)
8. ~~Authentik SSO~~ (done)
9. ~~Media stack (Servarr + Jellyfin)~~ (done)
10. ~~Public internet access (VPS relay + client VPN)~~ (done)
11. ~~Immich photo library~~ (done)
12. ~~Home Assistant~~ (done)
13. Service deployment (Nextcloud, Forgejo, Paperless-ngx, ...)
