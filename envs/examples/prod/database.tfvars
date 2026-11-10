instance_class        = "db.t4g.small"
allocated_storage     = 50
max_allocated_storage = 200
multi_az              = true

deletion_protection            = true
apply_immediately              = false # changes go through the maintenance window
backup_retention_days          = 14
aws_backup_retention_days      = 35
aws_backup_vault_force_destroy = false
