# Every IAM role of this environment. People and CI get access by assuming a role; the cluster
# only knows role names (eks reads them from this stack's outputs).
#
# Applied by a person, never by scripts/run-env.sh: it holds the role the CI apply workflow runs with.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name       = "${var.project}-${var.env}"
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  bucket_arn = "arn:${local.partition}:s3:::${var.state_bucket}"

  # CI roles only in the account they were meant for: a clone applied elsewhere gets none.
  ci_wrong_account = var.github_repo != null && var.github_aws_account_id != local.account_id
  create_ci        = var.github_repo != null && !local.ci_wrong_account
  subject_prefixes = coalesce(var.github_subject_prefixes, ["repo:${coalesce(var.github_repo, "none/none")}"])
}

################################################################################
# CI roles
################################################################################

check "ci_account" {
  assert {
    condition     = !local.ci_wrong_account
    error_message = "CI roles skipped: github_repo ${coalesce(var.github_repo, "-")} is meant for account ${coalesce(var.github_aws_account_id, "-")}, this is ${local.account_id}. Set github_repo and github_aws_account_id for your copy in envs/base/access.tfvars."
  }
}

# Plan: read-only AWS, read-only state (lock files only, so `plan` can still lock).
data "aws_iam_policy_document" "state_read" {
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
    resources = ["${local.bucket_arn}/*.tflock"]
  }
}

module "github_plan" {
  source = "../../modules/github-oidc-role"
  count  = local.create_ci ? 1 : 0

  name            = "${local.name}-github-plan"
  subjects        = [for p in local.subject_prefixes : "${p}:*"]
  policy_arns     = ["arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"]
  inline_policies = { terraform-state-read = data.aws_iam_policy_document.state_read.json }
}

# Apply: only jobs bound to the GitHub Environment named like this env (never plain PR runs).
module "github_apply" {
  source = "../../modules/github-oidc-role"
  count  = local.create_ci ? 1 : 0

  name              = "${local.name}-github-apply"
  subjects          = [for p in local.subject_prefixes : "${p}:environment:${var.env}"]
  policy_arns       = var.github_apply_policy_arns
  max_session_hours = 2 # a whole environment (apply all / destroy all) takes ~30 min
}

################################################################################
# People: admin and viewer
################################################################################

# What scripts/tunnel.sh and scripts/kubeconfig.sh call, scoped to this env's bastion and cluster.
# What each role may do inside Kubernetes is decided by eks (EKS access entries).
data "aws_iam_policy_document" "cluster_access" {
  statement {
    sid       = "FindBastion"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
  statement {
    sid       = "DescribeCluster"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${local.partition}:eks:${var.region}:${local.account_id}:cluster/${local.name}"]
  }
  statement {
    sid       = "TunnelToBastion"
    actions   = ["ssm:StartSession"]
    resources = ["arn:${local.partition}:ec2:${var.region}:${local.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = ["${local.name}-bastion"]
    }
  }
  statement {
    sid       = "PortForwardDocument"
    actions   = ["ssm:StartSession"]
    resources = ["arn:${local.partition}:ssm:${var.region}::document/AWS-StartPortForwardingSessionToRemoteHost"]
  }
  statement {
    sid       = "OwnSessions"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:${local.partition}:ssm:*:*:session/$${aws:userid}-*"]
  }
}

module "admin" {
  source = "../../modules/assumable-role"

  name            = "${local.name}-admin"
  principal_arns  = var.admin_principal_arns
  inline_policies = { cluster-access = data.aws_iam_policy_document.cluster_access.json }
}

module "viewer" {
  source = "../../modules/assumable-role"

  name            = "${local.name}-viewer"
  principal_arns  = var.viewer_principal_arns
  inline_policies = { cluster-access = data.aws_iam_policy_document.cluster_access.json }
}
