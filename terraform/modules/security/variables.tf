###############################################################################
# modules/security/variables.tf — Security Groups module inputs
###############################################################################

variable "vpc_id" {
  description = "VPC ID to create security groups in"
  type        = string
}

variable "project_name" {
  description = "Project name for resource tagging"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH into instances"
  type        = string
  default     = "0.0.0.0/0"
}

variable "app_ports" {
  description = "Application ports to expose publicly"
  type = list(object({
    port        = number
    description = string
  }))
  default = [
    { port = 3000, description = "Voting Frontend" },
    { port = 3001, description = "Voting Backend API" },
  ]
}

variable "monitoring_ports" {
  description = "Monitoring ports to expose publicly"
  type = list(object({
    port        = number
    description = string
  }))
  default = [
    { port = 9090, description = "Prometheus" },
    { port = 3000, description = "Grafana" },
    { port = 16686, description = "Jaeger UI" },
  ]
}

variable "extra_tags" {
  description = "Additional tags to merge onto all resources"
  type        = map(string)
  default     = {}
}
