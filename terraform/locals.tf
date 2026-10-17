# ──────────────────────────────────────────────────────────────────────────────
# locals.tf — Centralised naming prefix and common tags
# ──────────────────────────────────────────────────────────────────────────────

locals {
  # Single prefix used across every resource name
  name_prefix = "${var.project_name}-${var.environment}"

  # Common tags applied to every resource
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
