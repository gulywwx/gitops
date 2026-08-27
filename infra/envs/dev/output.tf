output "rds_endpoint" {
  description = "RDS instance endpoint"
  value       = module.rds.db_instance_endpoint
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

# The three below are consumed by 00_deploy.sh. Without them the bootstrap
# scripts fall back to asking the operator to paste ARNs from the AWS console.

output "vpc_id" {
  description = "ID of the VPC the cluster runs in - needed by the ALB controller"
  value       = module.vpc.vpc_id
}

output "alb_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller"
  value       = module.iam.alb_controller_role_arn
}

output "eso_role_arn" {
  description = "IRSA role ARN for the External Secrets Operator"
  value       = module.iam.eso_role_arn
}

output "acm_certificate_arn" {
  description = "Self-signed certificate ARN the shared Gateway terminates TLS with"
  value       = module.acm.certificate_arn
}

output "internal_domain" {
  description = "Base domain the Gateway listener and every HTTPRoute hostname derive from"
  value       = module.acm.internal_domain
}