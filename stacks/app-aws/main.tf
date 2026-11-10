data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "eks.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "database" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "database.tfstate"
    region = var.region
  }
}

data "aws_eks_cluster" "this" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

locals {
  name = data.terraform_remote_state.eks.outputs.cluster_name # <project>-<env>
  db   = data.terraform_remote_state.database.outputs

  # Every DB secret uses the aws/secretsmanager key, so no KMS grant is needed.
  user_secret = { for k, u in local.db.db_user_secrets : k => u.secret_arn }

  # Pods that only read DB secrets: the Job that keeps the MySQL users in sync (logs in as master),
  # and ProxySQL (logs in to MySQL as the app and monitor users).
  secret_readers = {
    db-admin = {
      namespace       = var.db_admin_namespace
      service_account = var.db_admin_service_account
      secrets         = concat([local.db.db_master_secret_arn], values(local.user_secret))
    }
    proxysql = {
      namespace       = var.proxysql_namespace
      service_account = var.proxysql_service_account
      secrets         = values(local.user_secret)
    }
  }

  # Pod Identity roles: who (namespace / service account) may assume which role.
  pod_roles = merge(
    { app = { namespace = var.app_namespace, service_account = var.app_service_account } },
    { for k, r in local.secret_readers : k => { namespace = r.namespace, service_account = r.service_account } },
  )
}

# Bucket names are global: neutral prefix + random suffix (no account id in names).
resource "random_id" "suffix" {
  byte_length = 3
}

################################################################################
# S3: one bucket the app reads (list/get), one it writes (put)
################################################################################

module "read_bucket" {
  source = "../../modules/s3-bucket"

  name          = "${local.name}-app-read-${random_id.suffix.hex}"
  force_destroy = var.bucket_force_destroy
}

module "write_bucket" {
  source = "../../modules/s3-bucket"

  name                    = "${local.name}-app-write-${random_id.suffix.hex}"
  force_destroy           = var.bucket_force_destroy
  versioning              = true # app writes are never lost to an overwrite
  noncurrent_version_days = var.write_bucket_noncurrent_days
}

resource "aws_s3_object" "seed" {
  count = var.seed_read_bucket ? 1 : 0

  bucket       = module.read_bucket.id
  key          = "hello.txt"
  content      = "Hello from ${local.name} (seeded by Terraform)\n"
  content_type = "text/plain"
}

################################################################################
# SQS: work queue the app consumes + dead-letter queue
################################################################################

resource "aws_sqs_queue" "dlq" {
  name                      = "${local.name}-app-dlq"
  message_retention_seconds = 1209600 # 14 days (max) to investigate failures
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "main" {
  name                       = "${local.name}-app"
  visibility_timeout_seconds = var.queue_visibility_timeout_seconds
  message_retention_seconds  = var.queue_message_retention_seconds
  receive_wait_time_seconds  = 20 # long polling: fewer empty receives
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.queue_max_receive_count
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main.arn]
  })
}

################################################################################
# IAM roles for pods (EKS Pod Identity): the app, and db-admin (the app-k8s Job that keeps the
# app's MySQL user in sync with its secret)
################################################################################

data "aws_iam_policy_document" "assume" {
  for_each = local.pod_roles

  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    # Pod Identity session tags: only this cluster / namespace / service account may assume it.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [data.aws_eks_cluster.this.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [each.value.namespace]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [each.value.service_account]
    }
  }
}

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "ReadBucketList"
    actions   = ["s3:ListBucket"]
    resources = [module.read_bucket.arn]
  }
  statement {
    sid       = "ReadBucketGet"
    actions   = ["s3:GetObject"]
    resources = ["${module.read_bucket.arn}/*"]
  }
  statement {
    sid       = "WriteBucketPut"
    actions   = ["s3:PutObject"]
    resources = ["${module.write_bucket.arn}/*"]
  }
  statement {
    sid = "QueueConsume"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [aws_sqs_queue.main.arn]
  }

  # The app's own MySQL user, never the master one.
  statement {
    sid       = "DbSecretRead"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [local.user_secret.app]
  }
}

resource "aws_iam_role" "app" {
  name               = "${local.name}-app"
  assume_role_policy = data.aws_iam_policy_document.assume["app"].json
}

resource "aws_iam_role_policy" "app" {
  name   = "app-resources"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

# Binds the role to the ServiceAccount. The SA itself is created later by app-k8s;
# the association can exist first (the agent looks it up when the pod starts).
resource "aws_eks_pod_identity_association" "app" {
  cluster_name    = data.aws_eks_cluster.this.name
  namespace       = var.app_namespace
  service_account = var.app_service_account
  role_arn        = aws_iam_role.app.arn
}

# db-admin and proxysql: read their DB secrets, nothing else.
resource "aws_iam_role" "secret_reader" {
  for_each = local.secret_readers

  name               = "${local.name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.assume[each.key].json
}

data "aws_iam_policy_document" "secret_reader" {
  for_each = { for k, r in local.secret_readers : k => r if length(r.secrets) > 0 }

  statement {
    sid       = "DbSecretsRead"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = each.value.secrets
  }
}

resource "aws_iam_role_policy" "secret_reader" {
  for_each = data.aws_iam_policy_document.secret_reader

  name   = "db-secrets"
  role   = aws_iam_role.secret_reader[each.key].id
  policy = each.value.json
}

resource "aws_eks_pod_identity_association" "secret_reader" {
  for_each = local.secret_readers

  cluster_name    = data.aws_eks_cluster.this.name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.secret_reader[each.key].arn
}
