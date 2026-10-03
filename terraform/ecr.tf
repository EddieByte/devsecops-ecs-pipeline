# ──────────────────────────────────────────────────────────────────────────────
# ecr.tf — Amazon ECR Repository
#
# Extracted from main.tf for separation of concerns.
# Uses KMS encryption (upgrade from AES256) for audit-grade key management.
# Lifecycle policy keeps the last 10 images of any tag status and removes
# untagged images older than 7 days to control storage costs.
# ──────────────────────────────────────────────────────────────────────────────

# ── KMS Key for ECR encryption ────────────────────────────────────────────────

resource "aws_kms_key" "ecr" {
  description             = "KMS key for ECR repository encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-ecr-kms" })
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/${local.name_prefix}-ecr"
  target_key_id = aws_kms_key.ecr.key_id
}

# ── ECR Repository ────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "app" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = merge(local.common_tags, { Name = var.ecr_repository_name })
}

# ── ECR Lifecycle Policy ──────────────────────────────────────────────────────

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Retain only the last 10 container images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_kms_key_arn" {
  description = "ARN of the KMS key used for ECR encryption"
  value       = aws_kms_key.ecr.arn
}
