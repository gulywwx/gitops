output "certificate_arn" {
  description = "ARN of the imported self-signed certificate, consumed by the Gateway's LoadBalancerConfiguration"
  value       = aws_acm_certificate.this.arn
}

output "internal_domain" {
  description = "Base domain the certificate covers - the Gateway listener hostname and every HTTPRoute hostname derive from it"
  value       = var.internal_domain
}

output "certificate_pem" {
  description = "The leaf certificate in PEM form. Trust it locally to silence the browser warning: security.cert_pinning or Keychain import."
  value       = tls_self_signed_cert.leaf.cert_pem
}
