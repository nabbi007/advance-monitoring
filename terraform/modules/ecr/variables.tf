###############################################################################
# modules/ecr/variables.tf — ECR module inputs
###############################################################################

variable "repository_names" {
  description = "List of ECR repository names to create"
  type        = list(string)
  default     = ["voting-backend", "voting-frontend"]
}

variable "project_name" {
  description = "Project name for resource tagging"
  type        = string
}

variable "image_tag_mutability" {
  description = "Tag mutability setting (MUTABLE or IMMUTABLE)"
  type        = string
  default     = "MUTABLE"
}

variable "scan_on_push" {
  description = "Enable image scanning on push"
  type        = bool
  default     = true
}

variable "max_image_count" {
  description = "Maximum number of images to retain per repository"
  type        = number
  default     = 10
}

variable "extra_tags" {
  description = "Additional tags to merge onto all resources"
  type        = map(string)
  default     = {}
}
