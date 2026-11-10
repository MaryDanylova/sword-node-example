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
# Kubernetes identity the AWS role is bound to (must match app-k8s)
################################################################################

variable "app_namespace" {
  type    = string
  default = "app"
}

variable "app_service_account" {
  type    = string
  default = "node-example"
}

variable "db_admin_namespace" {
  description = "Namespace of the Job that manages the app's MySQL user (app-k8s); separate from the app, which never sees master credentials."
  type        = string
  default     = "db-admin"
}

variable "db_admin_service_account" {
  type    = string
  default = "db-admin"
}

variable "proxysql_namespace" {
  description = "Namespace of ProxySQL (app-k8s), the apps' only way to MySQL."
  type        = string
  default     = "proxysql"
}

variable "proxysql_service_account" {
  type    = string
  default = "proxysql"
}

################################################################################
# S3
################################################################################

variable "bucket_force_destroy" {
  description = "Allow `make down` to delete non-empty buckets (dev convenience; false for prod)."
  type        = bool
  default     = false
}

variable "write_bucket_noncurrent_days" {
  description = "Expire old object versions in the (versioned) write bucket after N days."
  type        = number
  default     = 30
}

variable "seed_read_bucket" {
  description = "Put a sample object in the read bucket, so `aws s3 ls` / `get-object` can be verified."
  type        = bool
  default     = true
}

################################################################################
# SQS
################################################################################

variable "queue_visibility_timeout_seconds" {
  type    = number
  default = 30
}

variable "queue_message_retention_seconds" {
  type    = number
  default = 345600 # 4 days
}

variable "queue_max_receive_count" {
  description = "Receives before a message moves to the DLQ."
  type        = number
  default     = 5
}
