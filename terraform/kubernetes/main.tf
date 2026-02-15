provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  ssh {
    agent    = true
    username = "root"

    node {
      name    = var.proxmox_node
      address = "10.10.0.2"
    }
  }
}

# --- SSH public key ---

data "local_file" "ssh_public_key" {
  filename = pathexpand(var.ssh_public_key_path)
}

# --- Control plane ---

resource "proxmox_virtual_environment_vm" "control_plane" {
  name      = var.control_plane.name
  node_name = var.proxmox_node
  vm_id     = var.control_plane.vm_id
  tags      = ["k8s", "control-plane", "terraform"]

  on_boot         = true
  started         = true
  stop_on_destroy = true

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = var.control_plane.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.control_plane.memory
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    interface    = "scsi0"
    datastore_id = var.datastore_id
    size         = var.control_plane.disk
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  network_device {
    model   = "virtio"
    bridge  = var.network_bridge
    vlan_id = var.network_vlan
  }

  initialization {
    datastore_id = var.datastore_id
    interface    = "ide2"

    dns {
      domain  = var.dns_domain
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = "${var.control_plane.ip}/24"
        gateway = var.network_gateway
      }
    }

    user_account {
      username = "debian"
      keys     = [trimspace(data.local_file.ssh_public_key.content)]
    }
  }

  agent {
    enabled = true
    trim    = true
  }

  operating_system {
    type = "l26"
  }

  serial_device {}
}

# --- Workers ---

resource "proxmox_virtual_environment_vm" "worker" {
  for_each = var.workers

  name      = each.value.name
  node_name = var.proxmox_node
  vm_id     = each.value.vm_id
  tags      = ["k8s", "worker", "terraform"]

  on_boot         = true
  started         = true
  stop_on_destroy = true

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    interface    = "scsi0"
    datastore_id = var.datastore_id
    size         = each.value.disk
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  # Data disk (HDD) — for local-path-provisioner persistent storage
  disk {
    interface    = "scsi1"
    datastore_id = var.data_datastore_id
    size         = var.worker_data_disk_size
    discard      = "on"
    ssd          = false
    iothread     = true
  }

  network_device {
    model   = "virtio"
    bridge  = var.network_bridge
    vlan_id = var.network_vlan
  }

  initialization {
    datastore_id = var.datastore_id
    interface    = "ide2"

    dns {
      domain  = var.dns_domain
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.network_gateway
      }
    }

    user_account {
      username = "debian"
      keys     = [trimspace(data.local_file.ssh_public_key.content)]
    }
  }

  agent {
    enabled = true
    trim    = true
  }

  operating_system {
    type = "l26"
  }

  serial_device {}
}
