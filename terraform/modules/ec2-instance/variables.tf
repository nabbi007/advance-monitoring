# modules/ec2-instance/variables.tf — Reusable EC2 instance module inputs
variable "instance_name" {
  description = "Name tag for the EC2 instance"
  type        = string
}

variable "instance_role" {
  description = "Role tag (e.g., app, observability)"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for the instance"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "Name of the EC2 key pair for SSH access"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID to launch the instance into"
  type        = string
}

variable "security_group_ids" {
  description = "List of security group IDs to attach"
  type        = list(string)
}

variable "iam_instance_profile" {
  description = "IAM instance profile name"
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "Size of the root EBS volume in GB"
  type        = number
  default     = 30
}

variable "root_volume_type" {
  description = "EBS volume type (gp3, gp2, io1, etc.)"
  type        = string
  default     = "gp3"
}

variable "user_data" {
  description = "User data script (base64-encoded or raw)"
  type        = string
  default     = ""
}

variable "project_name" {
  description = "Project name for tagging"
  type        = string
}

variable "extra_tags" {
  description = "Additional tags to merge onto the instance"
  type        = map(string)
  default     = {}
}

variable "depends_on_resources" {
  description = "Explicit dependencies (pass resource IDs to create ordering)"
  type        = list(string)
  default     = []
}
