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
packer/
  debian-13/
    debian-13.pkr.hcl           # Packer template (proxmox-iso builder)
    variables.pkr.hcl           # Variable definitions with defaults
    debian-13.auto.pkrvars.hcl  # User secrets (GITIGNORED)
    http/
      preseed.cfg               # Debian automated install preseed
    scripts/
      cleanup.sh                # Template sysprep (cloud-init reset, cleanup)
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
```

## Roadmap

1. ~~Proxmox base configuration~~ (done)
2. ~~Network VLANs (Proxmox + MikroTik)~~ (done)
3. ~~Packer VM template (Debian 13)~~ (done)
4. Terraform VM provisioning
5. Kubernetes cluster install
6. ArgoCD + service deployment
