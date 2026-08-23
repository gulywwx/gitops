variable "project" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (EKS)"
  type        = list(string)
}

variable "database_subnet_cidrs" {
  description = "CIDR blocks for database subnets (RDS)"
  type        = list(string)
}

variable "isolate_database_subnets" {
  description = <<-EOT
    Give the database subnets their own route table containing only the local
    route, with no path to the NAT or internet gateway.

    true  - RDS can be reached from inside the VPC but has no route out of it.
    false - database subnets share the private route table and inherit its
            0.0.0.0/0 -> NAT route.

    Set to false only if the database needs outbound access (S3 import/export,
    RDS-invoked Lambda). Normal replication, backups and monitoring do not
    traverse these route tables - RDS handles those out of band.
  EOT
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = <<-EOT
    Use one shared NAT gateway for all private subnets instead of one per AZ.

    true  - cheaper (~$33/mo saved), but the NAT is a single point of failure:
            if its AZ fails, private subnets in every other AZ lose egress
            (ECR pulls, STS, Secrets Manager) while their nodes stay running.
            Also incurs cross-AZ data transfer for non-local traffic.
    false - one NAT gateway + EIP per AZ; each AZ is self-contained for egress.

    Set to false in production.
  EOT
  type        = bool
  default     = true
}
