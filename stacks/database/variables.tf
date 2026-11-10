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
# Instance
################################################################################

variable "engine_version" {
  description = "MySQL major/minor version. A major-only value (\"8.4\") lets RDS pick the latest minor."
  type        = string
  default     = "8.4"
}

variable "parameter_group_family" {
  type    = string
  default = "mysql8.4"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial storage, GB (gp3)."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling, GB. 0 disables autoscaling."
  type        = number
  default     = 50
}

variable "multi_az" {
  description = "Standby in a second AZ (automatic failover). Doubles the instance cost."
  type        = bool
  default     = false
}

variable "db_name" {
  description = "Initial database created on a fresh instance (ignored on restore: the snapshot already has its databases)."
  type        = string
  default     = "app"
}

variable "master_username" {
  type    = string
  default = "admin"
}

variable "db_users" {
  description = <<-EOT
    MySQL users that the app-k8s Job keeps in sync with their secrets: app (privileges on db_name,
    used by the apps through ProxySQL) and monitor (USAGE only, ProxySQL health checks).
    Bump password_version to generate a new password (write-only: Terraform sees only this number).
  EOT
  type = object({
    app = optional(object({
      username         = optional(string, "app")
      password_version = optional(number, 1)
    }), {})
    monitor = optional(object({
      username         = optional(string, "proxysql_monitor")
      password_version = optional(number, 1)
    }), {})
  })
  default = {}

  validation {
    condition = alltrue([for u in [var.db_users.app.username, var.db_users.monitor.username] :
    can(regex("^[a-z][a-z0-9_]{0,31}$", u)) && u != var.master_username]) && var.db_users.app.username != var.db_users.monitor.username
    error_message = "db_users usernames: 1-32 of [a-z0-9_], starting with a letter, distinct, and not the master user."
  }
}

variable "db_user_secret_recovery_days" {
  description = "Days a deleted user secret can still be recovered (0 = delete at once, 7-30 otherwise)."
  type        = number
  default     = 7

  validation {
    condition     = var.db_user_secret_recovery_days == 0 || (var.db_user_secret_recovery_days >= 7 && var.db_user_secret_recovery_days <= 30)
    error_message = "db_user_secret_recovery_days must be 0 or 7-30."
  }
}

variable "deletion_protection" {
  description = "Block `terraform destroy` / console deletion. true for prod."
  type        = bool
  default     = false
}

variable "apply_immediately" {
  description = "Apply modifications now instead of in the next maintenance window."
  type        = bool
  default     = true
}

################################################################################
# Backups
################################################################################

variable "backup_retention_days" {
  description = "RDS automated backups + PITR window, days (1-35)."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be 1-35 (0 would disable automated backups and PITR)."
  }
}

variable "backup_window" {
  description = "Daily RDS automated backup window (UTC). Kept clear of the AWS Backup start time."
  type        = string
  default     = "03:00-04:00"
}

variable "maintenance_window" {
  type    = string
  default = "sun:04:30-sun:05:00"
}

variable "delete_automated_backups" {
  description = "false = keep automated backups after the instance is deleted, so PITR still works after `make down` (until retention expires)."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "false = take a final snapshot on destroy (restore it later with restore_snapshot_id)."
  type        = bool
  default     = false
}

variable "enable_aws_backup" {
  description = "AWS Backup vault + daily plan for the instance (on top of RDS automated backups)."
  type        = bool
  default     = true
}

variable "aws_backup_schedule" {
  description = "AWS Backup cron (UTC)."
  type        = string
  default     = "cron(0 5 * * ? *)"
}

variable "aws_backup_retention_days" {
  type    = number
  default = 14
}

variable "aws_backup_vault_force_destroy" {
  description = "Allow destroying the vault while it still has recovery points (dev convenience; false for prod)."
  type        = bool
  default     = false
}

################################################################################
# Restore when no instance exists (after make down / down-all): both null = fresh empty database.
# Passed once as an environment variable, never committed (ignored after creation; the other stacks
# do not declare it, so it can be set for a whole up-all):
#   TF_VAR_restore_snapshot_id=<id> make up-all ENV=<env>
# A live instance is restored side by side instead: make db-restore ENV=<env> ARGS='restore <point>'
################################################################################

variable "restore_snapshot_id" {
  description = "Create the instance from this DB snapshot (manual, final or AWS Backup snapshot ARN/identifier)."
  type        = string
  default     = null
}

variable "restore_point_in_time" {
  description = <<-EOT
    Create the instance by point-in-time restore. Source: source_dbi_resource_id (works after the
    source was deleted, from retained automated backups) or source_db_instance_identifier (source must exist).
    Time: restore_time (RFC3339, UTC) or use_latest_restorable_time = true.
  EOT
  type = object({
    source_dbi_resource_id        = optional(string)
    source_db_instance_identifier = optional(string)
    restore_time                  = optional(string)
    use_latest_restorable_time    = optional(bool)
  })
  default = null

  validation {
    condition = var.restore_point_in_time == null || (
      (try(var.restore_point_in_time.source_dbi_resource_id, null) != null) != (try(var.restore_point_in_time.source_db_instance_identifier, null) != null) &&
      (try(var.restore_point_in_time.restore_time, null) != null) != (coalesce(try(var.restore_point_in_time.use_latest_restorable_time, null), false))
    )
    error_message = "restore_point_in_time needs exactly one source (source_dbi_resource_id | source_db_instance_identifier) and exactly one of restore_time | use_latest_restorable_time = true."
  }
}
