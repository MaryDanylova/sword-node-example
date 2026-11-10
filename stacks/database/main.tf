data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "network.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "eks.tfstate"
    region = var.region
  }
}

locals {
  net  = data.terraform_remote_state.network.outputs
  eks  = data.terraform_remote_state.eks.outputs
  name = "${local.net.name}-mysql"

  restoring = var.restore_snapshot_id != null || var.restore_point_in_time != null
}

################################################################################
# Network access: MySQL only from the EKS nodes (pods use the node SG with the VPC CNI)
################################################################################

resource "aws_security_group" "db" {
  name        = local.name
  description = "MySQL - ingress from EKS nodes only"
  vpc_id      = local.net.vpc_id

  tags = { Name = local.name }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_nodes" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from EKS nodes/pods"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = local.eks.node_security_group_id
}

# No egress rules: RDS does not initiate connections.

################################################################################
# Instance
################################################################################

resource "aws_db_parameter_group" "this" {
  name_prefix = "${local.name}-"
  family      = var.parameter_group_family
  description = "${local.name}: TLS required"

  parameter {
    name = "require_secure_transport"
    # RDS stores booleans as 0/1: "ON" would show a diff on every plan.
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Final snapshot names must be unique. A new suffix per restore source, so a
# restore-then-destroy cycle never collides with an earlier final snapshot.
resource "random_id" "final_snapshot" {
  byte_length = 3
  keepers = {
    snapshot = coalesce(var.restore_snapshot_id, "none")
    pitr     = jsonencode(var.restore_point_in_time)
  }
}

resource "aws_db_instance" "this" {
  # <name>-<26 hex>: a side-by-side restore (scripts/py/db_restore.py) names its instance the same way,
  # so `terraform import` reads the same prefix back and the swap shows no diff.
  identifier_prefix = "${local.name}-"
  engine            = "mysql"
  engine_version    = var.engine_version
  instance_class    = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = local.net.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.multi_az
  parameter_group_name   = aws_db_parameter_group.this.name

  # Master credentials (admin only, apps use the app user above): RDS generates the password and
  # keeps it in Secrets Manager (rotated by RDS). It never appears in Terraform state - only the ARN.
  # On restore the snapshot brings its own databases/users; RDS resets the master password.
  username                    = local.restoring ? null : var.master_username
  db_name                     = local.restoring ? null : var.db_name
  manage_master_user_password = true

  # Restore paths (create-time only - see lifecycle below).
  snapshot_identifier = var.restore_snapshot_id

  dynamic "restore_to_point_in_time" {
    for_each = var.restore_point_in_time == null ? [] : [var.restore_point_in_time]
    content {
      source_dbi_resource_id        = restore_to_point_in_time.value.source_dbi_resource_id
      source_db_instance_identifier = restore_to_point_in_time.value.source_db_instance_identifier
      restore_time                  = restore_to_point_in_time.value.restore_time
      use_latest_restorable_time    = restore_to_point_in_time.value.use_latest_restorable_time
    }
  }

  # Backups: daily automated snapshot + transaction logs = PITR within the retention window.
  backup_retention_period  = var.backup_retention_days
  backup_window            = var.backup_window
  maintenance_window       = var.maintenance_window
  copy_tags_to_snapshot    = true
  delete_automated_backups = var.delete_automated_backups

  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = "${local.name}-final-${random_id.final_snapshot.hex}"
  deletion_protection       = var.deletion_protection

  auto_minor_version_upgrade      = true
  apply_immediately               = var.apply_immediately
  enabled_cloudwatch_logs_exports = ["error"]

  tags = { Name = local.name }

  lifecycle {
    # Create-time only:
    #   - Restore inputs: a later change must never replace a live database. A live instance is
    #     restored side by side instead (make db-restore).
    #   - username, db_name: a restored instance takes them from its data, and an imported one must
    #     not be replaced over them.
    ignore_changes = [snapshot_identifier, restore_to_point_in_time, username, db_name]

    precondition {
      condition     = !(var.restore_snapshot_id != null && var.restore_point_in_time != null)
      error_message = "Set either restore_snapshot_id or restore_point_in_time, not both."
    }
  }
}

################################################################################
# MySQL users for apps and ProxySQL, each with its own secret, so nothing uses the master user:
#   app      privileges on db_name only (the app connects as it, through ProxySQL)
#   monitor  USAGE only (ProxySQL health checks)
# The secrets are not tied to the instance: their ARNs survive every restore (a restored instance
# brings the users back with the data, mysql.user). The users themselves are created and kept in
# sync with these secrets by a Job in app-k8s (the only place with network access to the DB).
# Passwords are ephemeral and write-only: in neither the plan nor the state.
# Rotate: bump db_users.<user>.password_version and apply this stack and app-k8s.
################################################################################

locals {
  db_users = {
    app     = var.db_users.app
    monitor = var.db_users.monitor
  }
}

ephemeral "random_password" "db_user" {
  for_each = local.db_users

  length  = 32
  special = false # only [A-Za-z0-9]: safe to embed in SQL, shell and proxysql.cnf (the consumers check it)
}

resource "aws_secretsmanager_secret" "db_user" {
  for_each = local.db_users

  name_prefix             = "${local.name}-${each.key}-" # a deleted secret keeps its name for the recovery window
  description             = "MySQL ${each.key} user for ${local.name} (JSON: username, password)"
  recovery_window_in_days = var.db_user_secret_recovery_days
}

resource "aws_secretsmanager_secret_version" "db_user" {
  for_each = local.db_users

  secret_id = aws_secretsmanager_secret.db_user[each.key].id
  secret_string_wo = jsonencode({
    username = each.value.username
    password = ephemeral.random_password.db_user[each.key].result
  })
  secret_string_wo_version = each.value.password_version
}

################################################################################
# AWS Backup: independent daily recovery points in a dedicated vault
################################################################################

resource "aws_backup_vault" "this" {
  count = var.enable_aws_backup ? 1 : 0

  name          = local.name
  force_destroy = var.aws_backup_vault_force_destroy
}

resource "aws_backup_plan" "this" {
  count = var.enable_aws_backup ? 1 : 0

  name = local.name

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this[0].name
    schedule          = var.aws_backup_schedule
    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = var.aws_backup_retention_days
    }

    recovery_point_tags = {
      Project = var.project
      Env     = var.env
    }
  }
}

data "aws_iam_policy_document" "backup_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  count = var.enable_aws_backup ? 1 : 0

  name               = "${local.name}-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each = var.enable_aws_backup ? toset([
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores",
  ]) : toset([])

  role       = aws_iam_role.backup[0].name
  policy_arn = each.value
}

resource "aws_backup_selection" "this" {
  count = var.enable_aws_backup ? 1 : 0

  name         = local.name
  plan_id      = aws_backup_plan.this[0].id
  iam_role_arn = aws_iam_role.backup[0].arn
  resources    = [aws_db_instance.this.arn]
}
