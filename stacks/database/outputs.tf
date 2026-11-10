output "db_instance_identifier" {
  value = aws_db_instance.this.identifier
}

output "db_instance_arn" {
  value = aws_db_instance.this.arn
}

output "db_resource_id" {
  description = "dbi resource id - PITR source that keeps working after the instance is deleted (restore_point_in_time.source_dbi_resource_id)."
  value       = aws_db_instance.this.resource_id
}

output "db_address" {
  value = aws_db_instance.this.address
}

output "db_port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  description = "Initial database name (on a restored instance, whatever the snapshot contains)."
  value       = var.db_name
}

output "db_master_username" {
  value = aws_db_instance.this.username
}

output "db_master_secret_arn" {
  description = "Master user secret (JSON: username, password), managed and rotated by RDS. Admin only (db-sql.sh, the app-k8s user Job); new for every instance."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "db_master_secret_kms_key_id" {
  value = aws_db_instance.this.master_user_secret[0].kms_key_id
}

output "db_security_group_id" {
  value = aws_security_group.db.id
}

output "backup_vault_name" {
  value = try(aws_backup_vault.this[0].name, null)
}

output "db_user_secrets" {
  description = "Per MySQL user (app, monitor): username, secret ARN (stable across restores) and version id (changes with every new password)."
  value = { for k, u in local.db_users : k => {
    username   = u.username
    secret_arn = aws_secretsmanager_secret.db_user[k].arn
    version_id = aws_secretsmanager_secret_version.db_user[k].version_id
  } }
}
