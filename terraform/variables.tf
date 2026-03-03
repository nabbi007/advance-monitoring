###############################################################################
# variables.tf — Input Variables
###############################################################################

variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

# -----------------------------------------------------------------------
#  Instance sizing — separate so app and observability can differ
# -----------------------------------------------------------------------
variable "app_instance_type" {
  description = "EC2 instance type for the app server"
  type        = string
  default     = "t3.medium"
}

variable "observability_instance_type" {
  description = "EC2 instance type for the observability server"
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "Name of the EC2 key pair for SSH access"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for EC2 instances (leave empty for latest Ubuntu 22.04)"
  type        = string
  default     = ""
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH into instances"
  type        = string
  default     = "0.0.0.0/0"
}

variable "grafana_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
  default     = "admin123"
}

variable "project_name" {
  description = "Project name used for resource tagging"
  type        = string
  default     = "advance-monitoring"
}

variable "ecr_backend_image" {
  description = "ECR image URI for the voting backend (leave empty to build locally)"
  type        = string
  default     = ""
}

variable "ecr_frontend_image" {
  description = "ECR image URI for the voting frontend (leave empty to build locally)"
  type        = string
  default     = ""
}
