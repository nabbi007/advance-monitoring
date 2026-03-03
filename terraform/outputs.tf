###############################################################################
# outputs.tf — Terraform Outputs
###############################################################################

# -----------------------------------------------------------------------
#  App Instance
# -----------------------------------------------------------------------
output "app_instance_id" {
  description = "Instance ID of the app server"
  value       = module.app_instance.instance_id
}

output "app_instance_public_ip" {
  description = "Public IP of the app instance"
  value       = module.app_instance.public_ip
}

output "app_instance_private_ip" {
  description = "Private IP of the app instance"
  value       = module.app_instance.private_ip
}

# -----------------------------------------------------------------------
#  Observability Instance
# -----------------------------------------------------------------------
output "observability_instance_id" {
  description = "Instance ID of the observability server"
  value       = module.observability_instance.instance_id
}

output "observability_instance_public_ip" {
  description = "Public IP of the observability instance"
  value       = module.observability_instance.public_ip
}

output "observability_instance_private_ip" {
  description = "Private IP of the observability instance"
  value       = module.observability_instance.private_ip
}

# -----------------------------------------------------------------------
#  Convenience URLs
# -----------------------------------------------------------------------
output "app_url" {
  description = "URL to access the voting app"
  value       = "http://${module.app_instance.public_ip}:3000"
}

output "grafana_url" {
  description = "URL to access Grafana (systemd, port 3000)"
  value       = "http://${module.observability_instance.public_ip}:3000"
}

output "prometheus_url" {
  description = "URL to access Prometheus (systemd, port 9090)"
  value       = "http://${module.observability_instance.public_ip}:9090"
}

output "jaeger_url" {
  description = "URL to access Jaeger UI"
  value       = "http://${module.observability_instance.public_ip}:16686"
}

output "ssh_app" {
  description = "SSH command for app instance"
  value       = "ssh -i <key>.pem ubuntu@${module.app_instance.public_ip}"
}

output "ssh_observability" {
  description = "SSH command for observability instance"
  value       = "ssh -i <key>.pem ubuntu@${module.observability_instance.public_ip}"
}

# -----------------------------------------------------------------------
#  Ansible inventory helper — write to ../ansible/inventory/hosts.ini
# -----------------------------------------------------------------------
output "ansible_inventory" {
  description = "Paste into ansible/inventory/hosts.ini (or use the generate-inventory local-exec)"
  value       = <<-EOT
    [app]
    ${module.app_instance.public_ip} ansible_user=ubuntu

    [observability]
    ${module.observability_instance.public_ip} ansible_user=ubuntu

    [app:vars]
    observability_private_ip=${module.observability_instance.private_ip}

    [observability:vars]
    app_private_ip=${module.app_instance.private_ip}
  EOT
}
