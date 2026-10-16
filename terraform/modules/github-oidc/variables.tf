# ------------------------------------------------------------------------------
# modules/github-oidc/variables.tf
#
# All inputs required (or defaulted) by the github-oidc module.
# ------------------------------------------------------------------------------

variable "github_org_id" {
  description = "GitHub organisation or user numeric ID. Found in the OIDC token sub claim as 'EddieByte@<id>'. Run the debug step in the workflow to find it."
  type        = string
}

variable "github_repo_id" {
  description = "GitHub repository numeric ID. Found in the OIDC token sub claim as 'repo-name@<id>'. Run the debug step in the workflow to find it."
  type        = string
}

variable "github_org" {
  description = "GitHub organisation or user account that owns the repository (e.g. 'my-org')"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name without the org prefix (e.g. 'devsecops-ecs-pipeline')"
  type        = string
}

variable "role_name" {
  description = "Name of the IAM role assumed by GitHub Actions"
  type        = string
  default     = "github-actions-oidc-role"
}

variable "managed_policy_arns" {
  description = <<-EOT
    List of IAM managed policy ARNs to attach to the role.
    Add only what each job actually needs - keep this least-privilege.
  EOT
  type        = list(string)
  default     = []
}

variable "inline_policy_json" {
  description = <<-EOT
    Optional inline policy JSON string granting fine-grained permissions
    that no managed policy covers exactly (e.g. scoped Secrets Manager access).
    Pass an empty string to skip.
  EOT
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to the OIDC provider and IAM role"
  type        = map(string)
  default     = {}
}
