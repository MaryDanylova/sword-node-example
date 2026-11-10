# CI access to the private EKS API: a CodeBuild project inside the VPC that runs Terraform for the
# stacks that talk to Kubernetes (k8s_stacks), so CI needs no SSM tunnel.
#
#   - scripts/run-env.sh starts a build for those stacks with K8S_VIA=codebuild (apply.yml sets it).
#     People use the tunnel by default.
#   - Optional, and eks knows nothing about it: without CI (github_repo not set in access) this stack
#     creates nothing and needs no GitHub connection.
#   - Who can start a build: principals with codebuild:StartBuild on the project (the CI apply role,
#     admins). The plan role is read-only.
#   - The build role is cluster-admin, may write only the state of k8s_stacks, and may read this env's
#     database secrets: a DB restore sets the users on the new instance before it switches to it.

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

data "terraform_remote_state" "access" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "access.tfstate"
    region = var.region
  }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  net         = data.terraform_remote_state.network.outputs
  eks         = data.terraform_remote_state.eks.outputs
  github_repo = try(data.terraform_remote_state.access.outputs.github_repo, null)
  enabled     = local.github_repo != null
  partition   = data.aws_partition.current.partition
  bucket_arn  = "arn:${local.partition}:s3:::${var.state_bucket}"
  account_id  = data.aws_caller_identity.current.account_id
  # Same prefix as the database stack's instances and user secrets; this stack is applied before it.
  db_prefix = "${local.net.name}-mysql-"
}

data "aws_codestarconnections_connection" "github" {
  count = local.enabled ? 1 : 0
  name  = var.github_connection_name
}

check "github_connection" {
  assert {
    condition     = !local.enabled || try(data.aws_codestarconnections_connection.github[0].connection_status, "") == "AVAILABLE"
    error_message = "Connection '${var.github_connection_name}' is not AVAILABLE: finish the GitHub handshake in the console (docs/DEPLOYMENT.md)."
  }
}

# State: read every stack (terraform_remote_state), write only k8s_stacks (state + lock file).
data "aws_iam_policy_document" "state" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arn}/*"]
  }
  statement {
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = flatten([for s in var.k8s_stacks : ["${local.bucket_arn}/${s}.tfstate", "${local.bucket_arn}/${s}.tfstate.tflock"]])
  }
}

# DB restore (scripts/py/db_restore.py, sync_users): the app and monitor secrets, and the master secret of
# any instance of this env. RDS names that one rds!db-<uuid>, and restores create new ones, so it is
# matched by the instance ARN RDS tags it with.
data "aws_iam_policy_document" "db_secrets" {
  statement {
    sid       = "DbUserSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:${local.partition}:secretsmanager:${var.region}:${local.account_id}:secret:${local.db_prefix}*"]
  }
  statement {
    sid       = "DbMasterSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:${local.partition}:secretsmanager:${var.region}:${local.account_id}:secret:rds!db-*"]
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/aws:rds:primaryDBInstanceArn"
      values   = ["arn:${local.partition}:rds:${var.region}:${local.account_id}:db:${local.db_prefix}*"]
    }
  }
}

module "build" {
  source = "../../modules/vpc-codebuild"
  count  = local.enabled ? 1 : 0

  name               = "${local.net.name}-ci-runner" # scripts/py/codebuild.py uses the same name
  description        = "Terraform for ${join(", ", var.k8s_stacks)} and the DB restore cutover from inside the VPC (scripts/py/codebuild.py)"
  github_repo        = local.github_repo
  connection_arn     = data.aws_codestarconnections_connection.github[0].arn
  vpc_id             = local.net.vpc_id
  subnet_ids         = local.net.private_subnet_ids
  log_retention_days = var.log_retention_days
  inline_policies = {
    terraform-state = data.aws_iam_policy_document.state.json
    db-secrets      = data.aws_iam_policy_document.db_secrets.json
  }

  # Set per build by scripts/py/codebuild.py: ENV, STACK, TARGET, ARGS, CONFIRM, TF_VERSION, TF_STATE_BUCKET.
  buildspec = templatefile("${path.module}/buildspec.yml.tftpl", {
    kubectl_version = var.kubectl_version
    uv_version      = var.uv_version
  })
}

resource "aws_eks_access_entry" "build" {
  count         = local.enabled ? 1 : 0
  cluster_name  = local.eks.cluster_name
  principal_arn = module.build[0].role_arn
}

resource "aws_eks_access_policy_association" "build" {
  count         = local.enabled ? 1 : 0
  cluster_name  = local.eks.cluster_name
  principal_arn = aws_eks_access_entry.build[0].principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

resource "aws_vpc_security_group_ingress_rule" "cluster_from_build" {
  count                        = local.enabled ? 1 : 0
  security_group_id            = local.eks.cluster_security_group_id
  description                  = "EKS API from the CodeBuild project (ci-runner)"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = module.build[0].security_group_id
}
