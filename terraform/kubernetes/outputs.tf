output "control_plane_ip" {
  description = "Control plane static IP"
  value       = var.control_plane.ip
}

output "worker_ips" {
  description = "Worker node IPs"
  value       = { for k, v in var.workers : k => v.ip }
}

output "ssh_command" {
  description = "SSH to control plane"
  value       = "ssh debian@${var.control_plane.ip}"
}
