variable "project" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "repositories" {
  description = "List of ECR repository names to create"
  type        = list(string)
}

variable "force_delete" {
  description = "Allow destroying a repository that still contains images. Intended for ephemeral environments; leave false in prod so a destroy cannot silently discard released artifacts."
  type        = bool
  default     = false
}