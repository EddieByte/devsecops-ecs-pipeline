# ------------------------------------------------------------------------------
# modules/github-oidc/main.tf
#
# Provisions:
#   1. AWS IAM OIDC Identity Provider for GitHub Actions
#      (idempotent - one provider per AWS account, shared across all repos)
#   2. IAM Role with a trust policy scoped to a single GitHub repository
#   3. Managed policy attachments (caller-supplied list)
#   4. Optional inline policy for fine-grained permissions
#
# How it works:
#   GitHub Actions mints a short-lived OIDC token per job. The
#   configure-aws-credentials action exchanges that token for temporary STS
#   credentials by calling sts:AssumeRoleWithWebIdentity. No static keys
#   are stored anywhere - not in GitHub Secrets, not in code.
#
# Trust policy conditions:
#   - aud = "sts.amazonaws.com"  (required by the AWS STS endpoint)
#   - sub LIKE "repo:<org>/<repo>:*"  (scopes trust to one repository only)
#     Using StringLike so any branch, tag, or environment ref matches.
#     Tighten to a specific branch/tag pattern if you need stricter control,
#     e.g. "repo:<org>/<repo>:ref:refs/tags/*" for tag-only pipelines.
# ------------------------------------------------------------------------------

# -- GitHub OIDC IdP thumbprint ------------------------------------------------
# We look up the existing OIDC provider rather than creating a new one.
# AWS allows only ONE OIDC provider per URL per account - it is a shared
# account-level singleton. If you are on a shared account (common when using
# a friend's or org's AWS account), the provider already exists. Attempting
# to create it again throws EntityAlreadyExists.
#
# The data source performs a read-only lookup - no AWS resource is created
# or modified. The role below references it the same way either way.

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# -- IAM Role ------------------------------------------------------------------

resource "aws_iam_role" "github_actions" {
  name        = var.role_name
  description = "Assumed by GitHub Actions via OIDC - ${var.github_org}/${var.github_repo}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GitHubActionsOIDC"
        Effect = "Allow"
        Principal = {
          Federated = data.aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          # StringLike allows any ref (branch, tag, environment) in this repo.
          # To lock down to tags only, change to:
          #   "repo:${var.github_org}/${var.github_repo}:ref:refs/tags/*"
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
          }
        }
      }
    ]
  })

  tags = merge(var.tags, { Name = var.role_name })
}

# -- Managed Policy Attachments ------------------------------------------------

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset(var.managed_policy_arns)

  role       = aws_iam_role.github_actions.name
  policy_arn = each.value
}

# -- Inline Policy (optional) --------------------------------------------------
# Only created when the caller passes a non-empty inline_policy_json.
# Use this for scoped Secrets Manager, EC2 SG mutation, or ECS permissions
# that no AWS managed policy covers with the right scope.

resource "aws_iam_role_policy" "inline" {
  count = var.inline_policy_json != "" ? 1 : 0

  name   = "${var.role_name}-inline-policy"
  role   = aws_iam_role.github_actions.id
  policy = var.inline_policy_json
}
