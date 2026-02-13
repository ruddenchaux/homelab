# Homelab

Infrastructure as Code for a single-node Proxmox homelab running Kubernetes (k3s).

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
| Cluster | k3s |
| GitOps | ArgoCD + Helm |
| Secrets | SOPS + age |

## Project Structure

```
ansible/
  requirements.yml              # Collection dependencies (community.routeros, ansible.netcommon)
  inventory/
    hosts.yml                   # Proxmox + MikroTik hosts
    group_vars/
      mikrotik.yml              # RouterOS connection settings
  playbooks/
    proxmox-base.yml            # Base Proxmox configuration
    network-vlans.yml           # VLAN setup on MikroTik + Proxmox
  roles/
    proxmox-repos/              # Disable enterprise, enable no-subscription repos
    system-upgrade/             # apt upgrade + reboot if needed
    zfs-datapool/               # Create ZFS mirror on data HDDs
    ssh-hardening/              # Key-only auth, disable root password login
    mikrotik-guest-cleanup/     # Remove leftover guest WiFi experiment
    mikrotik-vlans/             # Bridge VLAN table, VLAN interfaces, firewall
    proxmox-networking/         # VLAN-aware bridge, management IP, DNS
```

## Network

| VLAN | Name | Subnet | Gateway |
|------|------|--------|---------|
| 1 | Default | 192.168.88.0/24 | 192.168.88.1 |
| 10 | Management | 10.10.0.0/24 | 10.10.0.1 |
| 20 | Trusted LAN | 10.20.0.0/24 | 10.20.0.1 |
| 30 | Kubernetes | 10.30.0.0/24 | 10.30.0.1 |

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
```

## Roadmap

1. ~~Proxmox base configuration~~ (done)
2. ~~Network VLANs (Proxmox + MikroTik)~~ (done)
3. Packer VM template (Debian 13)
4. Terraform VM provisioning
5. k3s cluster install
6. ArgoCD + service deployment
