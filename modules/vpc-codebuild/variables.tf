variable "name" {
  description = "CodeBuild project, role and log group name."
  type        = string
}

variable "description" {
  type    = string
  default = null
}

variable "github_repo" {
  description = "Source repository, \"owner/repo\"; each build names the commit (--source-version)."
  type        = string
}

variable "connection_arn" {
  description = "CodeConnections GitHub connection (AVAILABLE) that can read github_repo."
  type        = string
}

variable "buildspec" {
  description = "Buildspec (YAML) run for every build."
  type        = string
}

variable "inline_policies" {
  description = "What the build itself may do: name => policy JSON."
  type        = map(string)
  default     = {}
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnets with egress (NAT): builds download from GitHub and registries."
  type        = list(string)
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "build_timeout" {
  description = "Minutes a build may run."
  type        = number
  default     = 60
}

variable "compute_type" {
  type    = string
  default = "BUILD_GENERAL1_SMALL"
}

variable "image" {
  type    = string
  default = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
}
