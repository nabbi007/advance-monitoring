###############################################################################
# modules/ecr/outputs.tf — ECR module outputs
###############################################################################

output "repository_urls" {
  description = "Map of repository name → repository URL"
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "repository_arns" {
  description = "Map of repository name → repository ARN"
  value       = { for k, v in aws_ecr_repository.this : k => v.arn }
}

output "registry_id" {
  description = "ECR registry ID (AWS account ID)"
  value       = values(aws_ecr_repository.this)[0].registry_id
}

output "backend_repository_url" {
  description = "ECR URL for the voting-backend image"
  value       = aws_ecr_repository.this["voting-backend"].repository_url
}

output "frontend_repository_url" {
  description = "ECR URL for the voting-frontend image"
  value       = aws_ecr_repository.this["voting-frontend"].repository_url
}
