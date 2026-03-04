###############################################################################
# modules/security/outputs.tf — Security Groups module outputs
###############################################################################

output "app_security_group_id" {
  description = "Security group ID for the app instance"
  value       = aws_security_group.app.id
}

output "monitoring_security_group_id" {
  description = "Security group ID for the observability/monitoring instance"
  value       = aws_security_group.monitoring.id
}

output "app_security_group_arn" {
  description = "Security group ARN for the app instance"
  value       = aws_security_group.app.arn
}

output "monitoring_security_group_arn" {
  description = "Security group ARN for the observability/monitoring instance"
  value       = aws_security_group.monitoring.arn
}
