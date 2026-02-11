# Homelab IaC Project

## Project Overview
Building a professional homelab with Infrastructure as Code. The owner is a software engineer with 13 years of experience, learning Proxmox and Kubernetes for the first time. This project serves multiple purposes: data privacy, cost savings, learning, CV enhancement, and blog content.

## Hardware
- **Server**: Dell R740xd 2U 12LFF (refurbished)
- **CPU**: 2x Intel Xeon Gold 6140 (18C/36T each)
- **RAM**: 6x 16GB DDR4 2666MHz (96GB total)
- **Storage Controller**: Dell H740p Mini 8GB cache — configured in **Enhanced HBA (eHBA) mode**, all disks as Non-RAID
- **Boot Storage**: 2x 960GB SAS SSD — ZFS mirror (rpool), Proxmox installed here
- **Data Storage**: 2x 4TB SAS HDD 7.2K — to be configured as ZFS mirror (datapool)
- **NIC**: BCM57416 (2x 10G, ports 1-2) + BCM5720 (2x 1G, ports 3-4)
- **PSU**: 2x 1100W Platinum
- **Router**: MikroTik L009UiGS-2HaxD-IN (SFP port max 2.5G)
- **Service Tag**: H3L6FW2

## Current State
- All firmware updated (iDRAC 7.00.00.183, BIOS 2.25.0, H740p 51.16.0-5150, Broadcom NIC 23.3/23.3.1, CPLD 1.1.4)
- H740p in eHBA mode, 4 disks as Non-RAID
- Proxmox VE 8.3 installed on ZFS mirror (2x SSD)
- Server connected to MikroTik via 1G port (BCM5720) because 10G<->2.5G speed mismatch
- Proxmox accessible at https://192.168.88.187:8006
- SSH access configured with ed25519 key from dev-box

## Pending Tasks (in order)
1. **Ansible: Configure Proxmox base** (NEXT)
   - Disable enterprise repos, enable no-subscription repo
   - Full system upgrade
   - Install useful packages
   - Create ZFS datapool mirror on the 2 HDDs
   - SSH hardening
2. **Ansible: Configure networking/VLANs on Proxmox and MikroTik**
   - VLAN 10: Management (Proxmox, iDRAC, MikroTik admin)
   - VLAN 20: Trusted LAN (personal devices)
   - VLAN 30: Kubernetes/Services
   - VLAN 40: IoT (Home Assistant, NVR cameras)
   - VLAN 50: DMZ (VPN endpoint, reverse proxy)
   - VLAN 100: Storage/Ceph (future, inter-node)
3. **Packer: Create VM template** (Ubuntu 24.04 + cloud-init + qemu-guest-agent)
4. **Terraform: Provision VMs** (k3s control plane + workers)
5. **Ansible: Install k3s cluster**
6. **Helm/ArgoCD: Deploy services via GitOps**

## Services to Deploy (on k3s)
- Media server (Servarr stack)
- Storage/backup (Nextcloud)
- Home Assistant
- InfluxDB + Grafana + Node-RED
- Inventory app
- Git server (Forgejo) — bootstrap problem: needed before GitOps
- VPN mesh
- Wealth portfolio (Ghostfolio/Wealthfolio)
- NVR system
- Expense sharing app (Splitwise alternative)
- Document management (Paperless-ngx)

## Architecture Decisions
- **No RAID hardware**: eHBA mode + ZFS for checksumming, self-healing, snapshots
- **ZFS mirror on SSDs** for boot (managed by Proxmox installer)
- **ZFS mirror on HDDs** for bulk data (to be created via Ansible)
- **Future Ceph**: when second node is added (same rack), minimum 3 nodes needed. Third node at parents' house — use ZFS send/receive or Syncthing instead of Ceph for remote replication due to latency
- **VMs for k3s**: don't run k3s directly on Proxmox host. 1 VM control plane + 1-2 VM workers
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
- **Ansible** → post-provisioning, k3s install, Proxmox host config
- **Helm/ArgoCD** → k3s service deployment

## Dev Environment
- Fedora Kinoite (immutable) on laptop
- Distrobox (dev-box) with: Ansible, Terraform, Packer, Git, Neovim, Node, Go
- SSH key: ~/.ssh/id_ed25519

## Network Info
- Proxmox IP: 192.168.88.187
- MikroTik default subnet: 192.168.88.0/24
- MikroTik LAN gateway: 192.168.88.1
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
