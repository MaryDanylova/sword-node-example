# Base (every env): short AWS Backup retention, vault removable with the stack.
# Restore inputs are never set here. To see what can be restored: make db-restore ENV=<env> ARGS=list
aws_backup_retention_days      = 7
aws_backup_vault_force_destroy = true
db_user_secret_recovery_days   = 0 # deleted at once on make down (no secrets left pending deletion)
