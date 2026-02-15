packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

source "proxmox-iso" "debian-13" {
  # Proxmox connection
  proxmox_url              = var.proxmox_url
  node                     = var.proxmox_node
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = var.proxmox_skip_tls_verify

  # VM settings
  vm_id                = var.vm_id
  vm_name              = var.vm_name
  template_description = "Debian 13 cloud-init template, built ${timestamp()}"
  qemu_agent           = true

  # Hardware
  cores  = var.vm_cores
  memory = var.vm_memory
  cpu_type = "x86-64-v2-AES"

  # Disk
  scsi_controller = "virtio-scsi-single"
  disks {
    storage_pool = var.vm_storage
    disk_size    = var.vm_disk_size
    type         = "scsi"
    discard      = true
    ssd          = true
    io_thread    = true
  }

  # Data disk (HDD)
  disks {
    storage_pool = var.vm_data_storage
    disk_size    = var.vm_data_disk_size
    type         = "scsi"
    discard      = true
    ssd          = false
    io_thread    = true
  }

  # Network
  network_adapters {
    model    = "virtio"
    bridge   = var.network_bridge
    vlan_tag = var.network_vlan
  }

  # Cloud-init drive
  cloud_init              = true
  cloud_init_storage_pool = var.vm_storage

  # ISO
  boot_iso {
    iso_url          = var.iso_url
    iso_checksum     = var.iso_checksum
    iso_storage_pool = var.iso_storage_pool
    unmount          = true
  }

  # Boot command — ISOLINUX preseed with static network
  boot_wait = "5s"
  boot_command = [
    "<esc><wait>",
    "auto ",
    "url=http://${var.http_ip}:{{ .HTTPPort }}/preseed.cfg ",
    "hostname=${var.vm_name} ",
    "domain=local ",
    "interface=auto ",
    "netcfg/disable_autoconfig=true ",
    "netcfg/get_ipaddress=${var.build_ip} ",
    "netcfg/get_netmask=${var.build_netmask} ",
    "netcfg/get_gateway=${var.build_gateway} ",
    "netcfg/get_nameservers=${var.build_gateway} ",
    "netcfg/confirm_static=true ",
    "<enter>"
  ]

  # HTTP server for preseed
  http_directory = "http"
  http_bind_address = "0.0.0.0"

  # SSH communicator
  ssh_username = "root"
  ssh_password = var.ssh_password
  ssh_timeout  = "20m"
}

build {
  sources = ["source.proxmox-iso.debian-13"]

  # Install cloud-init and qemu-guest-agent
  provisioner "shell" {
    inline = [
      "apt-get update",
      "apt-get install -y cloud-init qemu-guest-agent",
      "systemctl enable qemu-guest-agent",
    ]
  }

  # Template cleanup
  provisioner "shell" {
    script = "scripts/cleanup.sh"
  }
}
