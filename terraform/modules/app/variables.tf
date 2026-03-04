###############################################################################
# modules/app/variables.tf — App module inputs
###############################################################################

variable "project_name" {
  description = "Project name used for naming and tagging"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the security group"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID to launch the instance in"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for the EC2 instance"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "EC2 key pair name"
  type        = string
}

variable "iam_instance_profile" {
  description = "IAM instance profile name"
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "Root EBS size in GB"
  type        = number
  default     = 30
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH"
  type        = string
  default     = "0.0.0.0/0"
}

variable "app_ports" {
  description = "Public ports to open on the app instance"
  type = list(object({
    port        = number
    description = string
  }))
  default = [
    { port = 3000, description = "Voting Frontend" },
    { port = 3001, description = "Voting Backend API" },
  ]
}

variable "aws_region" {
  description = "AWS region (passed to userdata)"
  type        = string
}

variable "monitoring_private_ip" {
  description = "Private IP of the observability instance (written to .env for OTLP)"
  type        = string
  default     = ""
}

variable "extra_tags" {
  description = "Additional tags to merge onto all resources"
  type        = map(string)
  default     = {}
}
