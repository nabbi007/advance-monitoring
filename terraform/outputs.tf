###############################################################################
# outputs.tf — Terraform Outputs
###############################################################################

# -----------------------------------------------------------------------
#  App Instance
# -----------------------------------------------------------------------
output "app_instance_id" {
  description = "Instance ID of the app server"
  value       = module.app.instance_id
}

output "app_instance_public_ip" {
  description = "Public IP of the app instance"
  value       = module.app.public_ip
}

output "app_instance_private_ip" {
  description = "Private IP of the app instance"
  value       = module.app.private_ip
}

# -----------------------------------------------------------------------
#  Observability Instance
# -----------------------------------------------------------------------
output "observability_instance_id" {
  description = "Instance ID of the observability server"
  value       = module.observability.instance_id
}

output "observability_instance_public_ip" {
  description = "Public IP of the observability instance"
  value       = module.observability.public_ip
}

output "observability_instance_private_ip" {
  description = "Private IP of the observability instance"
  value       = module.observability.private_ip
}

# -----------------------------------------------------------------------
#  ECR Repositories
# -----------------------------------------------------------------------
output "ecr_backend_repository_url" {
  description = "ECR URL for the voting-backend image"
  value       = module.ecr.backend_repository_url
}

output "ecr_frontend_repository_url" {
  description = "ECR URL for the voting-frontend image"
  value       = module.ecr.frontend_repository_url
}

output "ecr_registry" {
  description = "ECR registry URL (account.dkr.ecr.region.amazonaws.com)"
  value       = local.ecr_registry
}

# -----------------------------------------------------------------------
#  Region
# -----------------------------------------------------------------------
output "aws_region" {
  description = "AWS region used for this deployment"
  value       = var.aws_region
}

# -----------------------------------------------------------------------
#  VPC
# -----------------------------------------------------------------------
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

# -----------------------------------------------------------------------
#  SSH/Key
# -----------------------------------------------------------------------
output "key_name" {
  description = "EC2 key pair name"
  value       = aws_key_pair.deploy.key_name
}

output "ssh_private_key" {
  description = "Private SSH key for EC2 access (sensitive — write to file, never log)"
  value       = tls_private_key.deploy.private_key_pem
  sensitive   = true
}

# -----------------------------------------------------------------------
#  Convenience URLs
# -----------------------------------------------------------------------
output "app_url" {
  description = "URL to access the voting app"
  value       = "http://${module.app.public_ip}:3000"
}

output "grafana_url" {
  description = "URL to access Grafana (port 3000)"
  value       = "http://${module.observability.public_ip}:3000"
}

output "prometheus_url" {
  description = "URL to access Prometheus (port 9090)"
  value       = "http://${module.observability.public_ip}:9090"
}

output "jaeger_url" {
  description = "URL to access Jaeger UI"
  value       = "http://${module.observability.public_ip}:16686"
}

output "ssh_app" {
  description = "SSH command for app instance"
  value       = "ssh -i ~/.ssh/deploy_key.pem ubuntu@${module.app.public_ip}"
}

output "ssh_observability" {
  description = "SSH command for observability instance"
  value       = "ssh -i ~/.ssh/deploy_key.pem ubuntu@${module.observability.public_ip}"
}

# -----------------------------------------------------------------------
#  Ansible inventory helper
# -----------------------------------------------------------------------
output "ansible_inventory" {
  description = "Paste into ansible/inventory/hosts.ini (or use deploy.sh which auto-generates it)"
  value       = <<-EOT
    [app]
    app-01 ansible_host=${module.app.public_ip} private_ip=${module.app.private_ip}

    [observability]
    obs-01 ansible_host=${module.observability.public_ip} private_ip=${module.observability.private_ip}

    [all:vars]
    ansible_user=ubuntu
    app_private_ip=${module.app.private_ip}
    observability_private_ip=${module.observability.private_ip}
    ecr_registry=${local.ecr_registry}
    ecr_backend_repo=${module.ecr.backend_repository_url}
    ecr_frontend_repo=${module.ecr.frontend_repository_url}
    aws_region=${var.aws_region}
  EOT
}
