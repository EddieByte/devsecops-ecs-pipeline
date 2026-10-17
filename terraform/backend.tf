# ------------------------------------------------------------------------------
# backend.tf - Terraform Version Constraints & S3 Remote State Backend
#
# Terraform >= 1.11.0 supports native S3 state locking via conditional writes
# (use_lockfile = true). This eliminates the need for a DynamoDB lock table,
# reducing cost and operational overhead.
#
# HOW TO ENABLE REMOTE STATE:
#   1. Run bootstrap_s3.ps1 to create the bucket (only needed once per account).
#   2. Run: terraform init
#      Terraform will connect to the bucket automatically.
#
# WHY NO DYNAMODB:
#   Terraform 1.11+ uses S3 conditional writes for locking - a lightweight
#   object-level lock file is written to the same bucket. No separate
#   DynamoDB table or IAM permissions for DynamoDB are required.
# ------------------------------------------------------------------------------

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # -- Remote State ----------------------------------------------------------
  backend "s3" {
    bucket       = "petclinic-tfstate-997450571655"
    key          = "dev/ecs-ec2-pipeline.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true   # Native S3 locking - no DynamoDB required (>= 1.11.0)
  }
}
