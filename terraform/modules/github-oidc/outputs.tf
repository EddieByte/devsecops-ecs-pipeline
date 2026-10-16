# ------------------------------------------------------------------------------
# modules/github-oidc/outputs.tf
# ------------------------------------------------------------------------------

output "role_arn" {
  description = "ARN of the IAM role assumed by GitHub Actions. Set this as the AWS_ROLE_TO_ASSUME GitHub Secret."
  value       = aws_iam_role.github_actions.arn
}

output "role_name" {
  description = "Name of the IAM role"
  value       = aws_iam_role.github_actions.name
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC Identity Provider"
  value       = data.aws_iam_openid_connect_provider.github.arn
}
