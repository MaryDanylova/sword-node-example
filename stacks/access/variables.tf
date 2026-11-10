variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "region" {
  type = string
}

variable "state_bucket" {
  description = "This env's Terraform state bucket (the CI plan role may read it). Set by scripts/run-stack.sh (TF_VAR_state_bucket)."
  type        = string
}

################################################################################
# CI (GitHub Actions via the account's OIDC provider, see bootstrap/oidc)
################################################################################

variable "github_repo" {
  description = <<-EOT
    Repository whose workflows may assume the CI roles, "owner/repo". Null = no CI roles.
    Needs github_aws_account_id: the roles are only created in that account, so a clone applied
    in another account never trusts this repository.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.github_repo == null || can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must look like \"owner/repo\"."
  }
}

variable "github_aws_account_id" {
  description = "The only AWS account in which the CI roles are created. In any other account they are skipped with a warning."
  type        = string
  default     = null

  validation {
    condition     = var.github_repo == null || var.github_aws_account_id != null
    error_message = "github_repo needs github_aws_account_id (the account the CI roles belong to)."
  }
}

variable "github_subject_prefixes" {
  description = <<-EOT
    Start of the OIDC `sub` claim, without the run part. Null = ["repo:<github_repo>"].
    Override when GitHub puts immutable IDs into the claim, e.g. "repo:owner@123/repo@456" (see CloudTrail).
    Plan role: "<prefix>:*" (any run). Apply role: "<prefix>:environment:<env>" (only jobs bound to the GitHub Environment).
  EOT
  type        = list(string)
  default     = null
}

variable "github_apply_policy_arns" {
  description = "Managed policies of the apply role. AdministratorAccess keeps the demo simple; scope it down for real use."
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/AdministratorAccess"]
}

################################################################################
# People: cluster admin and viewer (granted in Kubernetes by eks)
################################################################################

variable "admin_principal_arns" {
  description = "Who may assume <project>-<env>-admin (cluster-admin). Empty = principals of this account allowed sts:AssumeRole."
  type        = list(string)
  default     = []
}

variable "viewer_principal_arns" {
  description = "Who may assume <project>-<env>-viewer (read-only). Empty = principals of this account allowed sts:AssumeRole."
  type        = list(string)
  default     = []
}

