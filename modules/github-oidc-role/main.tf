# IAM role that GitHub Actions workflows assume through the account's OIDC provider
# (bootstrap/oidc). Which runs may assume it is decided by the `sub` patterns, e.g.
#   repo:owner/repo:*                    every run of the repository (pull requests included)
#   repo:owner/repo:environment:prod     only jobs bound to the GitHub Environment "prod"

# Found by issuer URL: nobody copies the provider ARN around, and this module never changes it.
data "aws_iam_openid_connect_provider" "this" {
  url = var.oidc_url
}

locals {
  oidc_host = trimprefix(var.oidc_url, "https://")
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.this.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values   = var.subjects
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = var.max_session_hours * 3600
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each = toset(var.policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "this" {
  for_each = var.inline_policies

  name   = each.key
  role   = aws_iam_role.this.id
  policy = each.value
}
