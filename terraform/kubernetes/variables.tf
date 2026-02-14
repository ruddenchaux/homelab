# --- Proxmox connection ---

variable "proxmox_endpoint" {
  type    = string
  default = "https://10.10.0.2:8006"
}

variable "proxmox_api_token" {
  type      = string
  sensitive = true
}

variable "proxmox_insecure" {
  type    = bool
  default = true
}

variable "proxmox_node" {
  type    = string
  default = "pve01"
}

# --- Template ---

variable "template_vm_id" {
  type    = number
  default = 9000
}

# --- Storage ---

variable "datastore_id" {
  type    = string
  default = "local-zfs"
}

# --- Networking ---

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "network_vlan" {
  type    = number
  default = 30
}

variable "network_gateway" {
  type    = string
  default = "10.30.0.1"
}

variable "dns_servers" {
  type    = list(string)
  default = ["10.30.0.1"]
}

variable "dns_domain" {
  type    = string
  default = "k8s.local"
}

# --- SSH ---

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

# --- VM definitions ---

variable "control_plane" {
  type = object({
    name   = string
    vm_id  = number
    ip     = string
    cores  = number
    memory = number
    disk   = number
  })
  default = {
    name   = "k8s-ctrl-01"
    vm_id  = 200
    ip     = "10.30.0.10"
    cores  = 4
    memory = 8192
    disk   = 20
  }
}

variable "workers" {
  type = map(object({
    name   = string
    vm_id  = number
    ip     = string
    cores  = number
    memory = number
    disk   = number
  }))
  default = {
    worker-1 = {
      name   = "k8s-worker-01"
      vm_id  = 201
      ip     = "10.30.0.11"
      cores  = 8
      memory = 16384
      disk   = 50
    }
    worker-2 = {
      name   = "k8s-worker-02"
      vm_id  = 202
      ip     = "10.30.0.12"
      cores  = 8
      memory = 16384
      disk   = 50
    }
    worker-3 = {
      name   = "k8s-worker-03"
      vm_id  = 203
      ip     = "10.30.0.13"
      cores  = 8
      memory = 16384
      disk   = 50
    }
  }
}
