# ──────────────────────────────────────────────────────────────────────────────
# backend.tf — Terraform Version Constraints & S3 Remote State Backend
#
# Terraform >= 1.11.0 supports native S3 state locking via conditional writes
# (use_lockfile = true). This eliminates the need for a DynamoDB lock table,
# reducing cost and operational overhead.
#
# HOW TO ENABLE REMOTE STATE:
#   1. Create the S3 bucket (only needed once):
#      aws s3api create-bucket --bucket github-actions-tfstate-489205146758 --region us-east-1
#      aws s3api put-bucket-versioning --bucket github-actions-tfstate-489205146758 --versioning-configuration Status=Enabled
#      aws s3api put-bucket-encryption --bucket github-actions-tfstate-489205146758 \
#        --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
#
#   2. Uncomment the backend "s3" block below.
#
#   3. Run: terraform init -migrate-state
#      Terraform will copy the local state into S3 automatically.
#
# WHY NO DYNAMODB:
#   Terraform 1.11+ uses S3 conditional writes for locking — a lightweight
#   object-level lock file is written to the same bucket. No separate
#   DynamoDB table or IAM permissions for DynamoDB are required.
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # ── Remote State (uncomment to activate) ──────────────────────────────────
  # backend "s3" {
  #   bucket       = "github-actions-tfstate-489205146758"
  #   key          = "dev/ecs-ec2-pipeline.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true   # Native S3 locking — no DynamoDB required (>= 1.11.0)
  # }
}
