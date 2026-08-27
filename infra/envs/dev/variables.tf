variable "db_password" {
  description = "Master password for the RDS PostgreSQL database"
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "JWT signing secret for the application"
  type        = string
  sensitive   = true
}

variable "github_org" {
  description = "GitHub username or organization that owns frontend and backend"
  type        = string
  default     = "gulywwx"
}

variable "github_org_id" {
  description = "Numeric GitHub organization/owner ID. Fetch via: curl https://api.github.com/orgs/<github_org>"
  type        = string
  default     = "25069476"
}

variable "github_repo_ids" {
  description = "Map of GitHub repo name to its numeric GitHub repository ID. Fetch via: curl https://api.github.com/repos/<github_org>/<repo>"
  type        = map(string)
  default = {
    "gitops" = "1342817912"
  }
}

variable "internal_domain" {
  description = "Base domain served by the shared Gateway. Not registered publicly - reach it by pointing /etc/hosts at the ALB."
  type        = string
  default     = "pharma.internal"
}