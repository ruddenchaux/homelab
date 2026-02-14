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
- ZFS datapool mirror created on 2x 4TB HDDs, mounted at /datapool
- SSH hardened (PermitRootLogin=prohibit-password, PasswordAuthentication=no, PubkeyAuthentication=yes)
- Server connected to MikroTik via 1G port (BCM5720) because 10G<->2.5G speed mismatch
- VLAN segmentation configured: VLAN 10 (mgmt), VLAN 20 (trusted LAN), VLAN 30 (kubernetes)
- Proxmox management IP: 10.10.0.2 (VLAN 10), accessible at https://10.10.0.2:8006
- Proxmox node name: `pve01` (hostname `pve01.ruddenchaux.xyz`)
- `/etc/hosts` on Proxmox: `10.10.0.2 pve01.ruddenchaux.xyz pve01` (updated from old 192.168.88.187)
- Proxmox API token: `root@pam!packer-token` (privsep=0, used by Packer and Terraform)
- VM template 9000 (`debian-13-cloud`): Debian 13 + cloud-init + qemu-guest-agent
- SSH access configured with ed25519 key from dev-box

## Completed Tasks
1. **Ansible: Configure Proxmox base** — `ansible/playbooks/proxmox-base.yml`
   - Disabled enterprise repos, enabled no-subscription repos (PVE + Ceph Squid for Trixie)
   - Full system upgrade (83 packages)
   - Created ZFS datapool mirror on 2x 4TB HDDs (compression=lz4, atime=off)
   - SSH hardening (key-only auth, no X11 forwarding)
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

## Pending Tasks (in order)
1. **Terraform: Provision VMs** (k8s control plane + workers) (NEXT)
2. **Ansible: Install k8s cluster**
3. **Helm/ArgoCD: Deploy services via GitOps**

## Services to Deploy (on k8s)
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
- **ZFS mirror on HDDs** for bulk data (created via Ansible, mounted at /datapool)
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
