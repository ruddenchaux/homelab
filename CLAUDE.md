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

## Pending Tasks (in order)

1. **Deploy services via GitOps** (NEXT) — add service Applications to `kubernetes/`

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

## Public Internet Access (Research)

ISP: Starlink Residential Lite (CGNAT, no public IPv4). Options evaluated:

### Option A: VPS + WireGuard (~4 EUR/month) — most stable

- Hetzner CX22 in Nuremberg (~15ms from Milan), WireGuard tunnel to MikroTik (native support)
- Internet → VPS (public IP) → WireGuard tunnel → MikroTik → Traefik → pods
- Full control, no upload/streaming limits, end-to-end TLS with own certs, any protocol
- Fully transparent to existing Traefik + Authentik + cert-manager stack
- PersistentKeepalive=25 critical for CGNAT, WireGuard MTU 1420

### Option B: IPv6 direct + Cloudflare Proxy — zero cost, educational

- Starlink provides /56 via DHCPv6-PD (256 /64 subnets for internal networks)
- Bypass mode required (Starlink router blocks inbound IPv6)
- Prefix is dynamic but stable (changes during maintenance windows, reboots, firmware updates)
- MikroTik DHCPv6-PD client → assigns /64 per VLAN → SLAAC for downstream clients
- IPv6 firewall on MikroTik is critical — only allow TCP 80/443 to Traefik's specific IPv6 address
- K8s: do NOT rebuild for dual-stack. Keep IPv4 internal, add IPv6 entry point only
  - Cilium L2 announcement supports IPv6 via NDP — add IPv6 block to CiliumLoadBalancerIPPool
  - Traefik LoadBalancer with `ipFamilyPolicy: PreferDualStack`
  - Pod-to-pod, services, CoreDNS stay IPv4
- **Cloudflare proxy trick**: orange-cloud AAAA record → CF publishes both A+AAAA pointing to its edge → 100% visitor coverage with IPv6-only origin (free IPv4-to-IPv6 translation)
- Dynamic DNS: favonia/cloudflare-ddns as K8s pod with hostNetwork: true
- cert-manager DNS-01 unaffected (works via API, never inbound)
- Italy IPv6 adoption only ~13% — cannot go IPv6-only without Cloudflare proxy
- Starlink may silently block inbound IPv6 in some regions — must test empirically
- Cloudflare TOS: media streaming (Jellyfin) through proxy is a violation (actively enforced)
- Disable privacy extensions on k8s nodes: `net.ipv6.conf.all.use_tempaddr=0`
- Proxmox cloud-init `ip6=auto` is buggy — let SLAAC work at OS level

How Starlink IPv6 Works

  Starlink provides dual-stack connectivity:

- WAN /64: Assigned to your router's external interface via SLAAC
- LAN /56: Delegated via DHCPv6-PD — gives you 256 /64 subnets for internal networks

  For example, if you get 2a0d:5600:1234:ab00::/56, you can carve:

- 2a0d:5600:1234:ab00::/64 → VLAN 10 (Management)
- 2a0d:5600:1234:ab01::/64 → VLAN 20 (Trusted LAN)
- 2a0d:5600:1234:ab02::/64 → VLAN 30 (Kubernetes)

  Key facts:

- Bypass mode is required — the Starlink router blocks inbound IPv6 with no user-accessible
  firewall settings. You must bypass it and connect MikroTik directly to the dish
- Prefix is dynamic but relatively stable — changes primarily happen during maintenance windows
  (20:00-02:00 UTC), dish reboots, or firmware updates. You need Dynamic DNS
- Inbound IPv6 reliability is mixed — some users report it works perfectly, others report Starlink
  silently blocks inbound in certain regions. You need to test empirically
- Italy IPv6 adoption is only ~13% — you cannot go IPv6-only for public-facing services

  ---
  MikroTik Configuration

  DHCPv6-PD Client

  /ipv6 dhcp-client
  add interface=ether1 pool-name=starlink-pd pool-prefix-length=64 \
      request=prefix rapid-commit=no use-interface-duid=yes \
      use-peer-dns=yes add-default-route=yes

  Assign /64 subnets to VLANs

  /ipv6 address
  add address=::1 from-pool=starlink-pd interface=bridge.10 advertise=yes
  add address=::1 from-pool=starlink-pd interface=bridge.20 advertise=yes
  add address=::1 from-pool=starlink-pd interface=bridge.30 advertise=yes

  Router Advertisements (SLAAC)

  /ipv6 nd
  set [ find default=yes ] disabled=yes

  add interface=ether1 advertise-dns=no ra-lifetime=none
  add interface=bridge.30 hop-limit=64 mtu=1280 \
      managed-address-configuration=no other-configuration=yes \
      ra-interval=3m20s-10m \
      dns=2606:4700:4700::1111,2606:4700:4700::1001

  IPv6 Firewall (critical — every device gets a public address)

  /ipv6 firewall filter

# Input chain

  add chain=input action=accept connection-state=established,related,untracked
  add chain=input action=drop connection-state=invalid
  add chain=input action=accept protocol=icmpv6
  add chain=input action=accept protocol=udp dst-port=546 src-address=fe80::/10
  add chain=input action=drop in-interface-list=!LAN

# Forward chain

  add chain=forward action=accept connection-state=established,related,untracked
  add chain=forward action=drop connection-state=invalid
  add chain=forward action=accept protocol=icmpv6

# ONLY allow HTTP/HTTPS to Traefik's specific IPv6 address

  add chain=forward action=accept protocol=tcp \
      dst-address=<TRAEFIK_IPV6>/128 dst-port=80,443 \
      in-interface=ether1

  add chain=forward action=accept in-interface-list=LAN out-interface-list=WAN
  add chain=forward action=drop

  ---
  Kubernetes Integration (Minimal Changes)

  Do NOT rebuild your cluster for dual-stack. Keep IPv4 internally, just add an IPv6 entry point:

  1. K8s nodes get IPv6 via SLAAC — Debian picks up RAs automatically. Set
  net.ipv6.conf.eth0.accept_ra=2 via Ansible if needed
  2. Cilium L2 announcement supports IPv6 via NDP — add an IPv6 block to your
  CiliumLoadBalancerIPPool:
  spec:
    blocks:
      - start: "10.30.0.200"
        stop: "10.30.0.250"
      - cidr: "2a0d:5600:1234:ab02::c8/122"  # from your VLAN 30 /64
  3. Traefik gets dual-stack LoadBalancer:
  service:
    ipFamilyPolicy: PreferDualStack
    ipFamilies: [IPv4, IPv6]
  4. Pod-to-pod, services, CoreDNS — all stay IPv4, zero changes

  ---
  The Cloudflare Proxy Trick (This Makes It All Work)

  This is the key insight: when you orange-cloud (proxy) an AAAA record on Cloudflare:

- Cloudflare automatically publishes both A and AAAA records pointing to Cloudflare's edge
- IPv4 visitors → Cloudflare edge (IPv4) → your origin (IPv6)
- IPv6 visitors → Cloudflare edge (IPv6) → your origin (IPv6)
- Result: 100% of visitors can reach your services, even though your origin is IPv6-only

  This gives you free IPv4-to-IPv6 translation. No VPS needed.

  Dynamic DNS

  Deploy <https://github.com/favonia/cloudflare-ddns> as a pod with hostNetwork: true to detect the
  node's IPv6 and update Cloudflare AAAA records when the prefix changes.

  cert-manager

  No changes needed. DNS-01 challenges work via Cloudflare API calls (outbound). Let's Encrypt never
  connects inbound to your server.

  ---
  Recommended Strategy

  IPv6 direct + Cloudflare Proxy for IPv4 fallback:

  1. Put Starlink in bypass mode, configure MikroTik DHCPv6-PD
  2. Test inbound IPv6 connectivity (simple python3 -m http.server from a k8s node, test from an
  external IPv6 network)
  3. If it works → add IPv6 pool to Cilium, make Traefik dual-stack, deploy DDNS updater, enable
  Cloudflare proxy on AAAA records
  4. If Starlink blocks inbound IPv6 in your area → fall back to Cloudflare Tunnel (cloudflared as a
  pod, outbound-only, works through CGNAT without any IPv6)

  Both options cost nothing and use your existing Cloudflare DNS, cert-manager, and Traefik setup.

  ---
  Gotchas

- Prefix change cascade: When the /56 changes, ALL IPv6 addresses on ALL VLANs change. SLAAC
  re-advertises automatically, but there's a brief unreachability window (minutes)
- MikroTik firewall is non-optional: Without it, every k8s node, every pod network is directly
  reachable from the internet
- Disable privacy extensions on k8s nodes: net.ipv6.conf.all.use_tempaddr=0 — you need stable
  addresses for firewall rules and DNS
- Proxmox cloud-init ip6=auto is buggy — let SLAAC work at the OS level post-boot instead
- Cloudflare TOS still applies: media streaming (Jellyfin) through Cloudflare proxy is a TOS
  violation even with IPv6 origin. For Jellyfin, expose it directly on IPv6 (AAAA, DNS-only/grey
  cloud) and accept that only ~13% of Italian users can reach it directly

### Option C: Cloudflare Tunnel (free) — simplest fallback

- cloudflared as K8s pod, outbound tunnel to Cloudflare edge, zero inbound ports
- Works through CGNAT without any IPv6
- 100 MB upload limit per request (breaks Nextcloud/file uploads)
- TOS prohibits media streaming (Jellyfin) — actively enforced
- Cloudflare terminates TLS (cert-manager certs not used publicly)

### Not recommended

- Tailscale Funnel: no custom domains (only *.ts.net), breaks Authentik ForwardAuth cookie domain
- ngrok: too expensive ($8+/month for custom domains)

### Recommended strategy

1. Try IPv6 (Option B) first — educational, zero cost
2. If Starlink blocks inbound IPv6 → Cloudflare Tunnel (Option C) as immediate fallback
3. If upload limits or streaming TOS become a problem → VPS + WireGuard (Option A)

## Architecture Decisions

- **No RAID hardware**: eHBA mode + ZFS for checksumming, self-healing, snapshots
- **ZFS mirror on SSDs** for boot (managed by Proxmox installer)
- **ZFS mirror on HDDs** for bulk data (created via Ansible, mounted at /datapool, registered as Proxmox storage)
- **Kubernetes persistent storage**: local-path-provisioner on HDD data disks (500GB/worker, ext4, mounted at /data/local-path-provisioner). WaitForFirstConsumer binding, default StorageClass
- **Future Ceph**: when second node is added (same rack), minimum 3 nodes needed. Third node at parents' house — use ZFS send/receive or Syncthing instead of Ceph for remote replication due to latency
- **VMs for k8s**: don't run k8s directly on Proxmox host. 1 VM control plane + 1-2 VM workers
- **GitOps with ArgoCD**: all services declared in Git
- **Secrets**: SOPS + age or Vault
- **Monitoring**: Prometheus + Grafana + Loki
- **Certificates**: cert-manager + Let's Encrypt with DNS challenge
- **Backup**: Proxmox Backup Server (PBS) in VM/LXC, 3-2-1 rule
- **GPU**: planned for future AI workloads

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
