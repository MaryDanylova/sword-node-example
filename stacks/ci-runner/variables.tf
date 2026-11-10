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
  description = "Terraform state bucket, to read other stacks' outputs. Set by scripts/run-stack.sh (TF_VAR_state_bucket)."
  type        = string
}

variable "github_connection_name" {
  description = <<-EOT
    CodeConnections GitHub connection in this account and region, created once by a person
    (docs/DEPLOYMENT.md). Only looked up when access created CI roles (github_repo set).
  EOT
  type        = string
  default     = "github"
}

variable "k8s_stacks" {
  description = "Stacks the build runs (the ones with provider \"kubernetes\"): it may write only their state."
  type        = list(string)
  default     = ["app-k8s"]
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "kubectl_version" {
  description = "kubectl for the db-restore target (scripts/py/db_restore.py); within one minor of the cluster version."
  type        = string
  default     = "1.36.0"
}

variable "uv_version" {
  description = "uv for the db-restore target (scripts/py/main.py); same as the workflows' setup-uv."
  type        = string
  default     = "0.13.1"
}
