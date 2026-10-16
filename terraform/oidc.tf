# ------------------------------------------------------------------------------
# oidc.tf - GitHub Actions OIDC Federation
#
# Instantiates the github-oidc module to create:
#   - An AWS IAM OIDC Identity Provider for token.actions.githubusercontent.com
#   - An IAM Role with a trust policy scoped to this repository
#   - An inline policy granting exactly the permissions each pipeline job needs
#
# After applying, copy the role_arn output into GitHub Secrets as:
#   AWS_ROLE_TO_ASSUME = <role_arn output>
#
# No AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY are needed after this.
# ------------------------------------------------------------------------------

module "github_oidc" {
  source = "./modules/github-oidc"

  # -- Repository identity ----------------------------------------------------
  # Replace these with your actual GitHub org and repo name.
  github_org  = var.github_org
  github_repo = var.github_repo

  role_name = "${var.project_name}-github-actions-role"

  # -- Managed policies -------------------------------------------------------
  # ECR power user covers: ecr:GetAuthorizationToken, ecr:BatchGetImage,
  # ecr:PutImage, ecr:DescribeRepositories, etc.
  # AmazonECS_FullAccess covers: ecs:DescribeTaskDefinition,
  # ecs:RegisterTaskDefinition, ecs:UpdateService, ecs:DescribeServices.
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser",
    "arn:aws:iam::aws:policy/AmazonECS_FullAccess",
  ]

  # -- Inline policy ----------------------------------------------------------
  # Covers the permissions no managed policy above provides with the right scope:
  #   - Secrets Manager: read infra + DB credential secrets (DB_MIGRATE job)
  #   - EC2 SG: temporarily open/close port 3306 for the runner IP (DB_MIGRATE job)
  #   - IAM PassRole: required when registering a new ECS task definition revision
  #     that references the task execution role (DEPLOY job)
  inline_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadPipelineSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:dev/pipeline/infra*",
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:dev/app/rds*",
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:prod/pipeline/infra*",
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:prod/app/rds*"
        ]
      },
      {
        Sid    = "MutateRdsSecurityGroup"
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DescribeSecurityGroups"
        ]
        # Scoped to security groups in this account/region.
        # Terraform does not support resource-level conditions on SG mutations
        # without using aws:ResourceTag conditions - add a tag condition here
        # if you need stricter scoping.
        Resource = "*"
      },
      {
        Sid    = "PassTaskExecutionRole"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = aws_iam_role.ecs_task_execution.arn
      }
    ]
  })

  tags = var.tags
}

# -- Outputs -------------------------------------------------------------------

output "github_actions_role_arn" {
  description = "Paste this into GitHub Secrets as AWS_ROLE_TO_ASSUME"
  value       = module.github_oidc.role_arn
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC Identity Provider"
  value       = module.github_oidc.oidc_provider_arn
}
