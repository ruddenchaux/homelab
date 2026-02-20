# Homelab IaC Project

## Project Overview

Building a professional homelab with Infrastructure as Code. The owner is a software engineer with 13 years of experience, learning Proxmox and Kubernetes for the first time. This project serves multiple purposes: data privacy, cost savings, learning, CV enhancement, and blog content.

## Hardware

- **Server**: Dell R740xd 2U 12LFF (refurbished)
- **CPU**: 2x Intel Xeon Gold 6140 (18C/36T each)
- **RAM**: 6x 16GB DDR4 2666MHz (96GB total)
- **Storage Controller**: Dell H740p Mini 8GB cache — configured in **Enhanced HBA (eHBA) mode**, all disks as Non-RAID
- **Boot Storage**: 2x 960GB SAS SSD — ZFS mirror (rpool), Proxmox installed here
- **Data Storage**: 2x 4TB SAS HDD 7.2K — ZFS mirror (datapool), compression=lz4, atime=off
- **NIC**: BCM57416 (2x 10G, ports 1-2) + BCM5720 (2x 1G, ports 3-4)
- **PSU**: 2x 1100W Platinum
- **Router**: MikroTik L009UiGS-2HaxD-IN (SFP port max 2.5G)
- **Service Tag**: H3L6FW2

## Current State

- All firmware updated (iDRAC 7.00.00.183, BIOS 2.25.0, H740p 51.16.0-5150, Broadcom NIC 23.3/23.3.1, CPLD 1.1.4)
- H740p in eHBA mode, 4 disks as Non-RAID
- Proxmox VE 9.1.5 (Debian Trixie) installed on ZFS mirror (2x SSD), kernel 6.17.2-1-pve
- Enterprise repos disabled, no-subscription repos enabled (PVE + Ceph Squid)
- ZFS datapool mirror created on 2x 4TB HDDs, mounted at /datapool, registered as Proxmox storage backend
- SSH hardened (PermitRootLogin=prohibit-password, PasswordAuthentication=no, PubkeyAuthentication=yes)
- Server connected to MikroTik via 1G port (BCM5720) because 10G<->2.5G speed mismatch
- VLAN segmentation configured: VLAN 10 (mgmt), VLAN 20 (trusted LAN), VLAN 30 (kubernetes)
- Proxmox management IP: 10.10.0.2 (VLAN 10), accessible at <https://10.10.0.2:8006>
- Proxmox node name: `pve01` (hostname `pve01.ruddenchaux.xyz`)
- `/etc/hosts` on Proxmox: `10.10.0.2 pve01.ruddenchaux.xyz pve01` (updated from old 192.168.88.187)
- Proxmox API token: `root@pam!packer-token` (privsep=0, used by Packer and Terraform)
- VM template 9000 (`debian-13-cloud`): Debian 13 + cloud-init + qemu-guest-agent
- SSH access configured with ed25519 key from dev-box
- Cilium L2 announcements enabled, LoadBalancer IP pool 10.30.0.200-250
- ArgoCD installed (chart 7.8.0), app-of-apps pattern, self-managing
- Traefik ingress controller (LoadBalancer service, Cilium L2 IP)
- cert-manager with Cloudflare DNS-01, ClusterIssuers: letsencrypt-staging + letsencrypt-prod
- GitOps manifests in `kubernetes/` (apps/ = root app-of-apps, platform/ = umbrella charts)
- Hubble UI enabled (relay + ui via Cilium Helm upgrade), ingress at hubble.ruddenchaux.xyz
- kube-prometheus-stack (Prometheus + Grafana) in monitoring namespace, Grafana at grafana.ruddenchaux.xyz
- Loki log aggregation in loki namespace (SingleBinary mode, filesystem storage)
- Headlamp (Kubernetes dashboard) at dashboard.ruddenchaux.xyz (replaces archived kubernetes-dashboard)
- Homepage app launcher at home.ruddenchaux.xyz (k8s service discovery, RBAC)
- Authentik SSO at auth.ruddenchaux.xyz (identity provider, Traefik ForwardAuth middleware)
- Authentik SSO configured: ForwardAuth (forward-domain mode, *.ruddenchaux.xyz), OIDC for Grafana + ArgoCD
- All ingresses protected by ForwardAuth middleware (authentik-authentik-auth@kubernetescrd)
- Grafana OIDC: generic_oauth with Authentik, admin role mapping, envFromSecrets grafana-oidc
- ArgoCD OIDC: Authentik issuer, RBAC policy (authentik Admins → role:admin, default → role:readonly)
- Worker VMs have 500GB HDD data disk (scsi1 on datapool), mounted at /data/local-path-provisioner
- local-path-provisioner deployed as default StorageClass (`local-path`)
- Loki persistence enabled (10Gi PVC), Authentik PostgreSQL (8Gi) persistence enabled
- Media stack (Servarr) deployed in `media` namespace, all pods pinned to k8s-worker-01 for shared local-path PVC
  - qBittorrent (torrent) via Gluetun VPN sidecar (NordVPN WireGuard, Netherlands)
  - NZBGet (Usenet downloader) at nzbget.ruddenchaux.xyz (ForwardAuth disabled, built-in basic auth)
  - Radarr (movies), Sonarr (TV), Lidarr (music), Readarr (books), Prowlarr (indexer manager)
  - FlareSolverr (Cloudflare bypass proxy for Prowlarr)
  - Bazarr (subtitles), Jellyfin (media server), Seerr (media requests)
  - Recyclarr (TRaSH Guides auto-sync, daily cron)
  - Ansible role `media-config`: configures inter-service connections via REST APIs + port-forwards
  - Shared 400Gi `media-library` PVC at `/data/media`, per-service 2Gi config PVCs
  - All services on Homepage dashboard, most behind ForwardAuth (except Jellyfin, Seerr, NZBGet which have built-in auth)
- Public internet access via VPS relay + client VPN (Hetzner CX22, 89.167.62.126)
  - `jellyfin.ruddenchaux.xyz` A record → VPS IP (grey-cloud, DNS-only), nginx TCP stream → WireGuard tunnel → MikroTik → Traefik
  - nginx is a generic blind TCP passthrough — any service gets IPv4 access just by adding an A record pointing to the VPS
  - WireGuard tunnel: VPS (10.100.0.1/wg0) ↔ MikroTik (10.100.0.2/wg-vps), PersistentKeepalive=25s (CGNAT piercing)
  - Client VPN: Android/devices connect to VPS WireGuard, masquerade + IP forwarding routes traffic through existing tunnel
  - Client VPN split tunnel: 10.10.0.0/24, 10.20.0.0/24, 10.30.0.0/24 (all homelab VLANs)

## Completed Tasks

1. **Ansible: Configure Proxmox base** — `ansible/playbooks/proxmox-base.yml`
   - Disabled enterprise repos, enabled no-subscription repos (PVE + Ceph Squid for Trixie)
   - Full system upgrade (83 packages)
   - Created ZFS datapool mirror on 2x 4TB HDDs (compression=lz4, atime=off)
   - SSH hardening (key-only auth, no X11 forwarding)
   - Registered ZFS datapool as Proxmox storage backend (`pvesm add zfspool`, content: images,rootdir)
2. **Ansible: Configure networking/VLANs** — `ansible/playbooks/network-vlans.yml`
   - Cleaned up leftover MikroTik guest WiFi experiment (10.10.50.0/24)
   - VLAN 10 (Management): 10.10.0.0/24 — Proxmox at 10.10.0.2, MikroTik GW 10.10.0.1
   - VLAN 20 (Trusted LAN): 10.20.0.0/24 — personal devices
   - VLAN 30 (Kubernetes): 10.30.0.0/24 — k8s VMs
   - MikroTik bridge VLAN filtering, trunk on ether6, VLAN interfaces in LAN firewall list
   - Proxmox VLAN-aware bridge (vmbr0), management on vmbr0.10
   - DNS: Proxmox → MikroTik GW → AdGuardHome (10.10.20.2)
3. **Packer: Create VM template** — `packer/debian-13/`
   - Debian 13 netinst automated install via preseed
   - cloud-init + qemu-guest-agent installed
   - Template sysprep (machine-id truncated, SSH keys removed, cloud-init reset, root locked)
   - Build VM on VLAN 30 (10.30.0.100), Proxmox API token auth
   - Template ID 9000, stored on local-zfs
   - Second disk (HDD, datapool) included in template for data storage
4. **Terraform: Provision k8s VMs** — `terraform/kubernetes/`
   - bpg/proxmox provider, clones VM template 9000 (Debian 13 + cloud-init)
   - Control plane: k8s-ctrl-01 (VM 200), 10.30.0.10, 4 cores, 8GB RAM, 20GB disk
   - Workers: k8s-worker-01..03 (VM 201-203), 10.30.0.11-13, 8 cores, 16GB RAM, 50GB disk
   - All VMs on VLAN 30 (Kubernetes), static IPs via cloud-init
   - Cloud-init: user `debian`, SSH key injection, DNS via MikroTik GW
   - Workers use `for_each` map for stable resource addresses
   - Workers have 500GB HDD data disk (scsi1 on datapool) for persistent storage
5. **Ansible: Install k8s cluster** — `ansible/playbooks/kubernetes-install.yml`
   - kubeadm + containerd (from Docker repo) + Cilium CNI
   - Roles: k8s-prerequisites (all nodes), k8s-control-plane, k8s-workers
   - Control plane: kubeadm init, Helm install, Cilium via Helm chart
   - Workers: kubeadm join (serial: 1 to avoid API server race)
   - Pod CIDR 10.244.0.0/16, Service CIDR 10.96.0.0/12 (no VLAN conflicts)
   - Idempotent: stat checks before init/join
6. **Ansible: Bootstrap ArgoCD + GitOps platform** — `ansible/playbooks/argocd-bootstrap.yml`
   - Cilium L2 announcements enabled (LoadBalancer IP pool 10.30.0.200-250)
   - CiliumLoadBalancerIPPool + CiliumL2AnnouncementPolicy CRDs applied
   - ArgoCD installed via Helm (chart 7.8.0), server.insecure=true
   - Cloudflare API token secret created for cert-manager DNS-01 challenge
   - Root Application (app-of-apps) pointing to `kubernetes/apps/`
   - GitOps manifests in `kubernetes/` (apps + platform umbrella charts)
   - Platform services managed by ArgoCD: ArgoCD (self-managed), Traefik (LoadBalancer ingress), cert-manager (Let's Encrypt ClusterIssuers)
   - Roles: cilium-l2 (L2 load balancing), authentik-secrets (pre-create credentials), argocd (install + bootstrap)
7. **GitOps: Monitoring & dashboards** — `kubernetes/platform/` + `kubernetes/apps/templates/`
   - Hubble UI: enabled in Cilium via Ansible (hubble.relay + hubble.ui), ingress via ArgoCD
   - kube-prometheus-stack (chart 81.6.9): Prometheus + Grafana, Loki datasource pre-configured
   - Loki (chart 6.53.0): SingleBinary mode, filesystem storage, internal only
   - Headlamp (chart 0.40.0): Kubernetes dashboard, Traefik ingress, cert-manager TLS
   - Homepage (chart 2.1.0): app launcher with k8s service discovery, RBAC, pre-configured links
   - Sync waves: cert-manager(1) → loki(2) → monitoring(3)
   - All services exposed via Traefik ingress with Let's Encrypt TLS (DNS-01)
8. **GitOps: Authentik SSO** — `kubernetes/platform/authentik/` + `ansible/roles/authentik-secrets/`
   - Authentik (chart 2025.12.4): SSO identity provider with bundled PostgreSQL + Redis
   - Secrets pre-created via Ansible role (authentik-credentials: secret_key + postgresql password + bootstrap token)
   - Traefik ForwardAuth middleware deployed (authentik-auth) for future service protection
   - Ingress at auth.ruddenchaux.xyz with Let's Encrypt TLS
   - Sync wave: 2 (parallel with loki, after cert-manager)
9. **Storage: local-path-provisioner + persistence** — `ansible/roles/proxmox-storage/`, `ansible/roles/worker-data-disk/`, `terraform/kubernetes/`, `kubernetes/apps/templates/local-path-provisioner.yaml`
   - Registered ZFS datapool as Proxmox storage backend (Ansible proxmox-storage role)
   - 500GB HDD data disk added to worker VMs (Terraform scsi1, thin provisioned on datapool)
   - ext4 formatted and mounted at /data/local-path-provisioner on workers (Ansible worker-data-disk role)
   - local-path-provisioner (v0.0.34) deployed via ArgoCD as default StorageClass
   - Sync wave: 0 (before all services needing PVCs)
   - Loki persistence enabled (10Gi PVC, path_prefix /var/loki)
   - Authentik PostgreSQL (8Gi) persistence enabled (chart has no Redis subchart)
   - Packer template updated with second disk for future VM builds
10. **Ansible: Authentik SSO configuration** — `ansible/roles/authentik-config/` + `ansible/roles/authentik-secrets/`

- Bootstrap API token generated and stored in authentik-credentials secret
- Authentik configured via REST API (port-forward to authentik-server)
- Forward-domain proxy provider: single SSO cookie for *.ruddenchaux.xyz
- Grafana OAuth2 provider + application, k8s secret (grafana-oidc in monitoring)
- ArgoCD OAuth2 provider + application, k8s secret (argocd-oidc in argocd), argocd-secret patched
- Embedded outpost linked to all applications
- ForwardAuth annotation added to all service ingresses (hubble, dashboard, homepage, grafana, argocd)
- Grafana OIDC: generic_oauth, role mapping (admin group → Admin), signout redirect
- ArgoCD OIDC: Authentik issuer, RBAC (authentik Admins → role:admin, default readonly)
- Roles: authentik-secrets (bootstrap token), authentik-config (API configuration)
1. **GitOps: Media stack (Servarr)** — `kubernetes/platform/media/` + `ansible/roles/media-config/`
    - Helm umbrella chart with templates for all services (Deployment + Service + Ingress + PVC per service)
    - Shared helpers: `_helpers.tpl` (labels, selectors, LinuxServer env, volume mounts, ingress generation)
    - qBittorrent behind Gluetun VPN sidecar (NordVPN WireGuard), NZBGet standalone (Usenet is SSL-encrypted)
    - Prowlarr with FlareSolverr indexer proxy, Recyclarr daily TRaSH Guides sync via CronJob
    - Jellyfin media server, Seerr media requests UI
    - Ansible `media-config` role: reads API keys from config.xml, port-forwards to all services, configures via REST APIs
    - qBittorrent configured as torrent download client in Radarr, Sonarr, Lidarr, Readarr
    - NZBGet configured as Usenet download client in Radarr, Sonarr, Lidarr, Readarr
    - NZBGet config patched via `sed` (kubectl exec) — saveconfig API replaces entire config, not safe for partial updates
    - Prowlarr synced to all *arr apps, FlareSolverr added as indexer proxy
    - Bazarr connected to Radarr + Sonarr for subtitle management
    - Jellyfin libraries configured, Seerr linked to Jellyfin + Radarr + Sonarr
    - Media management settings (rename, hardlinks, root folders) + naming schemes configured per *arr app
    - Recyclarr API keys secret created for TRaSH Guides sync
    - ForwardAuth disabled on Jellyfin, Seerr, NZBGet ingresses (built-in auth, conflicts with ForwardAuth headers)
    - All services added to Homepage dashboard
11. **Public internet access: VPS relay + client VPN** — `ansible/playbooks/vps-relay.yml` + `ansible/playbooks/vps-client-vpn.yml`
    - Hetzner CX22 VPS (89.167.62.126, Debian 13, Nuremberg) as Jellyfin relay
    - nginx stream proxy: TCP 443/80 → WireGuard tunnel → MikroTik → Traefik (blind TCP passthrough, SNI-routed by Traefik)
    - WireGuard tunnel: VPS wg0 (10.100.0.1) ↔ MikroTik wg-vps (10.100.0.2), PersistentKeepalive=25s
    - MikroTik firewall rule: forward wg-vps → vlan30-kubernetes (fw-wg-vps-fwd)
    - Cloudflare A record `jellyfin.ruddenchaux.xyz → 89.167.62.126` (grey-cloud, DNS-only, managed by Ansible)
    - 3-play playbook design to exchange keys cross-play via hostvars before WireGuard restart
    - Client VPN: Android device gets WireGuard keypair, IP forwarding + MASQUERADE on VPS, split tunnel (all homelab VLANs)
    - QR code generated via qrencode and printed in Ansible debug output
    - wg syncconf hot-reload: adds client peer without restarting WireGuard (MikroTik tunnel stays up)
    - Roles: vps-relay (VPS setup), mikrotik-wireguard (MikroTik WireGuard), vps-client-vpn (client peer + VPN)

## Pending Tasks (in order)

1. **Deploy services via GitOps** — add service Applications to `kubernetes/`

## Services to Deploy (on k8s)

- ~~Media server (Servarr stack)~~
- Storage/backup (Nextcloud)
- Home Assistant
- Node-RED (Grafana already deployed for dashboards)
- Inventory app
- Git server (Forgejo) — bootstrap problem: needed before GitOps
- VPN mesh
- Wealth portfolio (Ghostfolio/Wealthfolio)
- NVR system
- Expense sharing app (Splitwise alternative)
- Document management (Paperless-ngx)

## Public Internet Access

ISP: Starlink Residential Lite (CGNAT, no public IPv4). See `PUBLIC_INTERNET.md` for full
protocol explanations (WireGuard tunnel design, VPS relay, client VPN).

### Deployed: VPS + WireGuard relay

- Hetzner CX22 VPS: `89.167.62.126` (Nuremberg, ~15ms from Milan, ~4€/month)
- Flow: Internet → VPS:443 (nginx TCP stream, blind passthrough) → WireGuard tunnel → MikroTik → Traefik → pods
- WireGuard: VPS `10.100.0.1/wg0` ↔ MikroTik `10.100.0.2/wg-vps`, `PersistentKeepalive=25s` (CGNAT)
- nginx is generic — any service gets IPv4 access by adding an A record pointing to the VPS IP
- `jellyfin.ruddenchaux.xyz` A → `89.167.62.126` (grey-cloud, DNS-only, no Cloudflare proxy — streaming TOS)
- Playbook: `ansible/playbooks/vps-relay.yml` (secrets loaded automatically from `ansible/secrets.sops.yml`)

### Deployed: Client VPN (road warrior)

- Android/devices connect to VPS via WireGuard, routed through existing tunnel to homelab
- Client IP: `10.100.0.10`, masquerade on VPS (Android traffic appears as `10.100.0.1` to MikroTik)
- Split tunnel: `10.10.0.0/24, 10.20.0.0/24, 10.30.0.0/24` (all homelab VLANs)
- Playbook: `ansible/playbooks/vps-client-vpn.yml` — generates keypair, prints QR code
- Add more devices: `-e vpn_client_name=laptop -e vpn_client_ip=10.100.0.11`

## Architecture Decisions

- **No RAID hardware**: eHBA mode + ZFS for checksumming, self-healing, snapshots
- **ZFS mirror on SSDs** for boot (managed by Proxmox installer)
- **ZFS mirror on HDDs** for bulk data (created via Ansible, mounted at /datapool, registered as Proxmox storage)
- **Kubernetes persistent storage**: local-path-provisioner on HDD data disks (500GB/worker, ext4, mounted at /data/local-path-provisioner). WaitForFirstConsumer binding, default StorageClass
- **Future Ceph**: when second node is added (same rack), minimum 3 nodes needed. Third node at parents' house — use ZFS send/receive or Syncthing instead of Ceph for remote replication due to latency
- **VMs for k8s**: don't run k8s directly on Proxmox host. 1 VM control plane + 1-2 VM workers
- **GitOps with ArgoCD**: all services declared in Git
- **Secrets**: SOPS + age (deployed — see Secrets Management section below)
- **Monitoring**: Prometheus + Grafana + Loki
- **Certificates**: cert-manager + Let's Encrypt with DNS challenge
- **Backup**: Proxmox Backup Server (PBS) in VM/LXC, 3-2-1 rule
- **GPU**: planned for future AI workloads

## Secrets Management

SOPS + age is deployed. Encrypted secret files are committed to git; only the age private key
(at `~/.config/sops/age/keys.txt`) is kept off-repo. `.sops.yaml` at the repo root configures
the age recipient for all `*.sops.yml` files.

### Secret files
- `ansible/secrets.sops.yml` — Cloudflare tokens, NordVPN key, Proxmox API token, VPS IP, ACME email
- `terraform/kubernetes/secrets.sops.yml` — Proxmox API token
- `packer/debian-13/secrets.sops.yml` — Proxmox token secret, http_ip

### Ansible — automatic decryption
`ansible.cfg` enables `community.sops.sops` vars plugin. Any playbook that includes
`vars_files: ["../secrets.sops.yml"]` gets secrets transparently decrypted at load time.
No `-e` flags needed:
```bash
ansible-playbook ansible/playbooks/vps-relay.yml
ansible-playbook ansible/playbooks/vps-client-vpn.yml
ansible-playbook ansible/playbooks/argocd-bootstrap.yml
```

### Edit a secret
```bash
sops ansible/secrets.sops.yml   # opens $EDITOR, re-encrypts on save
```

### Terraform
```bash
sops exec-file --output-type dotenv terraform/kubernetes/secrets.sops.yml \
  'terraform -chdir=terraform/kubernetes apply -var-file={}'
```

### Packer
```bash
sops exec-file --output-type json packer/debian-13/secrets.sops.yml \
  'packer build -var-file={} packer/debian-13/'
```

### New machine setup
Copy `~/.config/sops/age/keys.txt` from an existing machine — that's the only thing needed.

## IaC Stack

- **Packer** → VM templates
- **Terraform** (bpg/proxmox provider) → VM provisioning
- **Cloud-init** → first boot config
- **Ansible** → post-provisioning, k8s install, Proxmox host config
- **Helm/ArgoCD** → k8s service deployment

## Dev Environment

- Fedora Kinoite (immutable) on laptop
- Distrobox (dev-box) with: Ansible, Terraform, Packer, Git, Neovim, Node, Go
- SSH key: ~/.ssh/id_ed25519

## Network Info

- Proxmox management IP: 10.10.0.2 (VLAN 10)
- MikroTik default subnet: 192.168.88.0/24 (VLAN 1, untagged)
- MikroTik LAN gateway: 192.168.88.1
- VLAN 10 (Management): 10.10.0.0/24 — GW 10.10.0.1, Proxmox 10.10.0.2
- VLAN 20 (Trusted LAN): 10.20.0.0/24 — GW 10.20.0.1
- VLAN 30 (Kubernetes): 10.30.0.0/24 — GW 10.30.0.1
- Trunk port: MikroTik ether6 ↔ Proxmox nic0 (tagged VLANs 10,20,30)
- iDRAC: separate dedicated port (check IP in iDRAC network settings)
- Server NIC layout:
  - nic0 (tg3): BCM5720 port 3 — 1G
  - nic1 (tg3): BCM5720 port 4 — 1G
  - nic2 (bnxt_en): BCM57416 port 1 — 10G
  - nic3 (bnxt_en): BCM57416 port 2 — 10G
- Currently using 1G port for Proxmox management

## Important Notes

- Power consumption: ~150-200W idle, ~400W full load. Estimate ~€30-50/month electricity in Milan.
- Server is noisy (2U) — consider soundproofing or dedicated room.
- The user has a public domain that should be used for hostnames and certificates.
- MikroTik firewall blocks non-standard outbound ports from k8s VMs (e.g., port 563/NNTPS blocked). Use standard ports like 443 when available.
- Services with built-in basic auth (e.g., NZBGet) conflict with Traefik ForwardAuth — the `Authorization` header causes 503. Disable ForwardAuth on these ingresses.
- NZBGet's `saveconfig` JSON-RPC API replaces the entire config file (not a merge). Use `sed` via kubectl exec for partial config updates.
- WireGuard wg0.conf: do NOT add `ip route add` in PostUp for CIDRs already in peer AllowedIPs — wg-quick creates those routes automatically. Adding them again causes `RTNETLINK: File exists` on start. PostUp/PostDown for iptables rules is fine.
- `community.routeros` Ansible collection requires `paramiko`. On Fedora Kinoite `~/.local/lib/` may be owned by root (overlay bug) — fix: `sudo chown -R $USER:$USER ~/.local/lib/` then `pip3 install paramiko --user`.
- Ansible multi-play playbooks: standalone `tasks:` plays (without `roles:`) don't load role defaults — add `vars_files: ["{{ playbook_dir }}/../roles/<role>/defaults/main.yml"]` to load them.
- VPS relay nginx is a generic TCP passthrough — any additional service becomes IPv4-accessible simply by adding an A record pointing to `89.167.62.126`. No nginx reconfiguration needed.
- Client VPN and vps-relay share `wg0.conf.j2`. Re-running `vps-relay.yml` overwrites wg0.conf (drops client peers). Always re-run `vps-client-vpn.yml` after `vps-relay.yml` to restore client peers.
