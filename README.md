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
  inventory/hosts.yml
  playbooks/proxmox-base.yml
  roles/
    proxmox-repos/     # Disable enterprise, enable no-subscription repos
    system-upgrade/     # apt upgrade + reboot if needed
    zfs-datapool/       # Create ZFS mirror on data HDDs
    ssh-hardening/      # Key-only auth, disable root password login
```

## Usage

```bash
# Configure Proxmox base (repos, ZFS, SSH hardening)
ansible-playbook ansible/playbooks/proxmox-base.yml
```

## Roadmap

1. ~~Proxmox base configuration~~ (done)
2. Network VLANs (Proxmox + MikroTik)
3. Packer VM template (Debian 13)
4. Terraform VM provisioning
5. k3s cluster install
6. ArgoCD + service deployment
