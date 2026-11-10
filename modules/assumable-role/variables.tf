variable "name" {
  description = "Role name."
  type        = string
}

variable "principal_arns" {
  description = <<-EOT
    IAM principals allowed to assume the role: users, roles (SSO, another account), or account roots.
    Empty = only principals of this account that are allowed sts:AssumeRole (nobody external).
  EOT
  type        = list(string)
  default     = []
}

variable "policy_arns" {
  description = "Managed policies to attach."
  type        = list(string)
  default     = []
}

variable "inline_policies" {
  description = "Inline policies, name => JSON document."
  type        = map(string)
  default     = {}
}

variable "max_session_hours" {
  description = "Maximum session length (1-12). A role assumed from another role (role chaining) is capped at 1 hour by AWS."
  type        = number
  default     = 4

  validation {
    condition     = var.max_session_hours >= 1 && var.max_session_hours <= 12
    error_message = "max_session_hours must be between 1 and 12 (AWS limit)."
  }
}

variable "tags" {
  description = "Extra tags for the role (on top of the provider's default_tags)."
  type        = map(string)
  default     = {}
}
