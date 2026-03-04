###############################################################################
# variables.tf — Input Variables
###############################################################################

# -----------------------------------------------------------------------
#  AWS Region
# -----------------------------------------------------------------------
variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "eu-west-1"
}

# -----------------------------------------------------------------------
#  Networking
# -----------------------------------------------------------------------
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

# -----------------------------------------------------------------------
#  SSH / Access
# -----------------------------------------------------------------------
variable "ami_id" {
  description = "AMI ID for EC2 instances. Defaults to Ubuntu 22.04 LTS (eu-west-1). Override for other regions."
  type        = string
  # Ubuntu 22.04 LTS (Jammy) — eu-west-1, hvm-ssd (Canonical owner 099720109477)
  # Verify or find for your region: https://cloud-images.ubuntu.com/locator/ec2/
  default     = "ami-0d75513e7706cf2d9"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH into instances"
  type        = string
  default     = "0.0.0.0/0"
}

# -----------------------------------------------------------------------
#  Application
# -----------------------------------------------------------------------
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
