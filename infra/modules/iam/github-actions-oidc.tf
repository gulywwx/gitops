# ─── GitHub Actions OIDC Federation ─────────────────────────────────────────
#
# Allows GitHub Actions workflows in your repos to assume an IAM role
# without any long-lived AWS credentials stored in GitHub Secrets.
#
# How it works:
#   1. GitHub mints a short-lived OIDC token per workflow run
#   2. The workflow calls aws-actions/configure-aws-credentials with
#      role-to-assume: <this role ARN>
#   3. AWS validates the token against the registered OIDC provider and
#      issues temporary STS credentials (valid for 1 hour max)

resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = {
    Name    = "github-actions-oidc-provider"
    Project = var.project
  }
}

locals {
  # GitHub tightened OIDC sub claims on 2026-07-15: repos created after that date (or
  # opted in) mint tokens with immutable owner/repo IDs instead of the mutable name,
  # e.g. repo:org@<org_id>/repo@<repo_id>:ref:refs/heads/<branch>. Mutable-name subs
  # silently stop matching, so ideally the trust policy keys off IDs, not names.
  # https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws
  #
  # Immutable subject claims are opt-in per repo/org; gulywwx hasn't enabled it yet,
  # so GitHub still mints tokens with the legacy "org/repo" (no @id) sub claim. Both
  # formats are listed so this keeps working whenever gulywwx does opt in.

  # Branch refs the CI role may be assumed from. Must track the `push.branches`
  # filters in .github/workflows/ci-*.yml, which include 'release/**'.
  # `release/*` is a wildcard, not a literal — the sub condition below is
  # StringLike, and GitHub mints one sub per concrete ref (release/1.4 etc).
  github_oidc_branches = ["main", "develop", "release/*"]

  github_oidc_subs = flatten([
    for repo_name, repo_id in var.github_repo_ids : flatten([
      for branch in local.github_oidc_branches : [
        "repo:${var.github_org}@${var.github_org_id}/${repo_name}@${repo_id}:ref:refs/heads/${branch}",
        "repo:${var.github_org}/${repo_name}:ref:refs/heads/${branch}",
      ]
    ])
  ])
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_oidc_subs
    }
  }
}

resource "aws_iam_role" "github_actions_ci" {
  name                 = "${var.project}-${var.env}-github-actions-role"
  assume_role_policy   = data.aws_iam_policy_document.github_actions_assume_role.json
  max_session_duration = 3600

  tags = {
    Name    = "${var.project}-${var.env}-github-actions-role"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_iam_policy" "github_actions_ci_policy" {
  name        = "${var.project}-${var.env}-github-actions-policy"
  description = "Allow GitHub Actions CI to push images to ECR and read EKS cluster info"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages",
        ]
        Resource = "arn:aws:ecr:*:${var.aws_account_id}:repository/*"
      },
      {
        Sid    = "EKSRead"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_ci_policy_attachment" {
  role       = aws_iam_role.github_actions_ci.name
  policy_arn = aws_iam_policy.github_actions_ci_policy.arn
}