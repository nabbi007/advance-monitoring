###############################################################################
# modules/ec2-instance/outputs.tf — Instance outputs
###############################################################################

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "Public IPv4 address"
  value       = aws_instance.this.public_ip
}

output "private_ip" {
  description = "Private IPv4 address"
  value       = aws_instance.this.private_ip
}

output "public_dns" {
  description = "Public DNS hostname"
  value       = aws_instance.this.public_dns
}

output "private_dns" {
  description = "Private DNS hostname"
  value       = aws_instance.this.private_dns
}

output "arn" {
  description = "Instance ARN"
  value       = aws_instance.this.arn
}
