variable "name" {
  description = "Role name."
  type        = string
}

variable "subjects" {
  description = "Allowed `sub` claim patterns (StringLike), e.g. [\"repo:owner/repo:environment:dev\"]."
  type        = list(string)

  validation {
    condition     = length(var.subjects) > 0
    error_message = "At least one subject pattern is required; an empty list would trust no run at all."
  }
}

variable "oidc_url" {
  description = "Issuer URL of the OIDC provider (must already exist in the account, see bootstrap/oidc)."
  type        = string
  default     = "https://token.actions.githubusercontent.com"
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
  description = "Maximum session length (1-12)."
  type        = number
  default     = 1

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
