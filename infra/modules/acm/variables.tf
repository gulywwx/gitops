variable "project" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "internal_domain" {
  description = "Base domain the certificate is issued for. Never registered publicly - clients reach it through a /etc/hosts entry pointing at the ALB."
  type        = string
}

variable "validity_period_hours" {
  description = "Certificate lifetime in hours, defaulting to one year. Terraform does not renew on its own, so expiry means a manual taint and re-apply."
  type        = number
  default     = 8760
}
