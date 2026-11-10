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

################################################################################
# Control plane
################################################################################

variable "kubernetes_version" {
  description = "EKS Kubernetes version (stay within standard support to avoid extended-support fees)."
  type        = string
  default     = "1.36"
}

variable "endpoint_public_access" {
  description = "Also expose the API endpoint publicly (restricted to endpoint_public_access_cidrs). Keep false: access goes through the SSM tunnel."
  type        = bool
  default     = false
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public endpoint when endpoint_public_access = true."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "Refusing to open the API endpoint to 0.0.0.0/0."
  }
}

variable "extra_admin_role_names" {
  description = <<-EOT
    Roles managed outside access that also get cluster-admin, e.g. an IAM Identity Center (SSO) role.
    Names, not ARNs (the ARN is built from the current account); for SSO roles use the name without
    the path, e.g. "AWSReservedSSO_Admin_0123456789abcdef". The roles must exist before this stack is applied.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for n in var.extra_admin_role_names : can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", n))])
    error_message = "Give role names only (no ARN, no path)."
  }
}

variable "extra_viewer_role_names" {
  description = "Same as extra_admin_role_names, with read-only access (AmazonEKSViewPolicy)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for n in var.extra_viewer_role_names : can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", n))])
    error_message = "Give role names only (no ARN, no path)."
  }
}

variable "log_types" {
  description = "Control plane log types sent to CloudWatch."
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "log_retention_days" {
  type    = number
  default = 30
}

################################################################################
# Nodes
################################################################################

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_min_size" {
  description = "Node group minimum, also its size at creation (no autoscaler, so the group stays here)."
  type        = number
  default     = 2

  validation {
    condition     = var.node_min_size >= 1
    error_message = "node_min_size must be >= 1."
  }
}

variable "node_max_size" {
  description = "Node group maximum (headroom for an autoscaler, and for node replacement during upgrades)."
  type        = number
  default     = 3

  validation {
    condition     = var.node_max_size >= var.node_min_size
    error_message = "node_max_size must be >= node_min_size."
  }
}

################################################################################
# Access bastion
################################################################################

variable "enable_bastion" {
  description = "Create the SSM bastion used to tunnel to the private API. false = no laptop access (e.g. when only in-VPC CI is used)."
  type        = bool
  default     = true
}

variable "bastion_instance_type" {
  type    = string
  default = "t4g.nano"
}
