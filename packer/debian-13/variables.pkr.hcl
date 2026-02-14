variable "proxmox_url" {
  type    = string
  default = "https://10.10.0.2:8006/api2/json"
}

variable "proxmox_node" {
  type    = string
  default = "pve01"
}

variable "proxmox_token_id" {
  type    = string
  default = "root@pam!packer-token"
}

variable "proxmox_token_secret" {
  type      = string
  sensitive = true
}

variable "proxmox_skip_tls_verify" {
  type    = bool
  default = true
}

variable "iso_url" {
  type    = string
  default = "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.3.0-amd64-netinst.iso"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:c9f09d24b7e834e6834f2ffa565b33d6f1f540d04bd25c79ad9953bc79a8ac02"
}

variable "iso_storage_pool" {
  type    = string
  default = "local"
}

variable "vm_id" {
  type    = number
  default = 9000
}

variable "vm_name" {
  type    = string
  default = "debian-13-cloud"
}

variable "vm_storage" {
  type    = string
  default = "local-zfs"
}

variable "vm_disk_size" {
  type    = string
  default = "10G"
}

variable "vm_cores" {
  type    = number
  default = 2
}

variable "vm_memory" {
  type    = number
  default = 2048
}

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "network_vlan" {
  type    = number
  default = 30
}

variable "build_ip" {
  type    = string
  default = "10.30.0.100"
}

variable "build_netmask" {
  type    = string
  default = "255.255.255.0"
}

variable "build_gateway" {
  type    = string
  default = "10.30.0.1"
}

variable "http_ip" {
  type        = string
  description = "IP address of the machine running Packer (reachable from build VM)"
}

variable "ssh_password" {
  type    = string
  default = "packer"
}
