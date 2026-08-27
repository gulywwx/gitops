# ─── Self-signed wildcard certificate, imported into ACM ────────────────────
#
# ACM only issues certificates for domains it can validate, and validation
# requires public ownership. internal_domain is never registered, so the
# certificate is generated locally and pushed into ACM via import instead.
# ACM is still unavoidable: the ALB accepts certificates by ARN only and cannot
# read a Kubernetes Secret, so a PEM on disk gets us nowhere. AWS Private CA
# would issue this properly but bills ~$400/month.

resource "tls_private_key" "leaf" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "leaf" {
  private_key_pem = tls_private_key.leaf.private_key_pem

  subject {
    common_name  = "*.${var.internal_domain}"
    organization = var.project
  }

  # Browsers have ignored CN since Chrome 58 and match on SAN only, so the
  # wildcard has to appear here or every request fails ERR_CERT_COMMON_NAME_INVALID.
  # The apex is listed separately because a wildcard covers exactly one label:
  # it matches dev.pharma.internal but not pharma.internal itself.
  dns_names = [
    "*.${var.internal_domain}",
    var.internal_domain,
  ]

  validity_period_hours = var.validity_period_hours

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "this" {
  # Supplying private_key + certificate_body selects ACM's import path. The
  # alternative - domain_name + validation_method - is the issuance path and
  # would block forever waiting on a DNS validation record we cannot publish.
  private_key      = tls_private_key.leaf.private_key_pem
  certificate_body = tls_self_signed_cert.leaf.cert_pem

  # certificate_chain is intentionally absent. A self-signed leaf IS its own
  # issuer, so there is no intermediate to present; passing the leaf again here
  # makes ACM reject the import.

  tags = {
    Name    = "${var.project}-${var.env}-internal-cert"
    Env     = var.env
    Project = var.project
  }

  # The ALB listener holds a reference to this ARN. Replacing the certificate
  # in place would break that reference mid-apply, so the new one is created
  # and attached before the old one is removed.
  lifecycle {
    create_before_destroy = true
  }
}
