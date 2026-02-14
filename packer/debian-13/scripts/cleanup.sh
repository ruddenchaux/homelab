#!/usr/bin/env bash
set -euo pipefail

# Template sysprep — prepare VM for conversion to template

# Clean apt cache
apt-get -y autoremove --purge
apt-get -y clean

# Truncate machine-id (regenerated on clone)
truncate -s 0 /etc/machine-id

# Remove SSH host keys (regenerated on first boot)
rm -f /etc/ssh/ssh_host_*

# Remove temporary PermitRootLogin config
sed -i '/^PermitRootLogin yes/d' /etc/ssh/sshd_config

# Reset cloud-init state
cloud-init clean

# Truncate log files
find /var/log -type f -exec truncate -s 0 {} \;

# Clear bash history
unset HISTFILE
rm -f /root/.bash_history

# Lock root password (cloud-init will manage access)
passwd -l root

sync
