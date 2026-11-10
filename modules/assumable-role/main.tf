# IAM role that people (or other roles) assume explicitly: access is granted by listing a
# principal in the trust policy and taken away by removing it - never by touching the cluster.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  # Nobody listed -> trust only this account: the role exists (so others can reference it by
  # name), and only principals of this account that are allowed sts:AssumeRole can use it.
  principals = length(var.principal_arns) > 0 ? var.principal_arns : [
    "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
  ]
}

# Principals denied by scripts/py/revoke.py, read from the live role (it does not exist on the first apply).
data "aws_iam_roles" "existing" {
  name_regex = "^${var.name}$"
}

data "aws_iam_role" "current" {
  count = length(data.aws_iam_roles.existing.names)
  name  = var.name
}

locals {
  live_statements = flatten([for r in data.aws_iam_role.current : jsondecode(r.assume_role_policy).Statement])
  revoked         = flatten([for s in local.live_statements : s.Principal.AWS if try(s.Sid, "") == "RevokedPrincipals"])
  still_trusted   = length(var.principal_arns) == 0 ? local.revoked : tolist(setintersection(local.revoked, var.principal_arns))
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = local.principals
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = var.max_session_hours * 3600
  tags                 = var.tags

  # scripts/py/revoke.py adds an inline policy Terraform does not manage; it must not block a destroy.
  force_detach_policies = true

  # An apply rewrites the trust policy and drops the revoke Deny, so a revoked principal must not
  # be trusted any more by then. With an empty principal_arns the role trusts the whole account.
  lifecycle {
    precondition {
      condition     = length(local.still_trusted) == 0
      error_message = "${var.name}: revoked but still trusted: ${join(", ", local.still_trusted)}. Remove them from the role's principal ARNs in access.tfvars (if the list is empty, the role trusts the whole account: list who may assume it)."
    }
  }
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
