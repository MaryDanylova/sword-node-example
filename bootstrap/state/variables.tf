variable "project" {
  description = "Short project name, the prefix of every resource name."
  type        = string
}

variable "env" {
  description = "Environment name (the envs/overlays/<env>/ directory, passed by scripts/state.sh)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{1,20}$", var.env))
    error_message = "env must be 1-20 lower-case letters, digits or '-' (it is part of an S3 bucket name)."
  }
}

variable "region" {
  description = "AWS region of the bucket (and of the environment)."
  type        = string
}

variable "noncurrent_version_days" {
  description = "Days to keep previous versions of state files (the way back from a broken state)."
  type        = number
  default     = 90
}
