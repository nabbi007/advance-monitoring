###############################################################################
# modules/observability/outputs.tf — Observability module outputs
###############################################################################

output "instance_id" {
  description = "EC2 instance ID"
  value       = module.instance.instance_id
}

output "public_ip" {
  description = "Public IP of the observability instance"
  value       = module.instance.public_ip
}

output "private_ip" {
  description = "Private IP of the observability instance"
  value       = module.instance.private_ip
}

output "security_group_id" {
  description = "ID of the monitoring security group"
  value       = aws_security_group.this.id
}
