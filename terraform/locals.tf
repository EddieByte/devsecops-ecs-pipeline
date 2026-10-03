# ──────────────────────────────────────────────────────────────────────────────
# locals.tf — Centralised naming prefix and common tags
#
# All resource names are derived from a single name_prefix local so that
# renaming the project or changing environment only requires updating
# variables.tf — nothing else changes.
# ──────────────────────────────────────────────────────────────────────────────

locals {
  # Single prefix used across every resource name
  name_prefix = "${var.project_name}-${var.environment}"

  # ── Standardised resource names ─────────────────────────────────────────────
  vpc_name          = "${local.name_prefix}-vpc"
  ecr_repo_name     = "${local.name_prefix}-app"
  ecs_cluster_name  = "${local.name_prefix}-cluster"
  ecs_service_name  = "${local.name_prefix}-service"
  alb_name          = "${local.name_prefix}-alb"
  rds_identifier    = "${local.name_prefix}-db"

  # ── Common tags applied to every resource ────────────────────────────────────
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
