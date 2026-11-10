# A CodeBuild project inside a VPC that runs a buildspec on a commit of a GitHub repository, for work
# that must reach private endpoints (here: Terraform for the stacks that talk to the private EKS API).
#
#   - Builds start on demand (scripts/py/codebuild.py). There is no webhook, so nothing in GitHub can
#     start one.
#   - The role can write its logs, read the source through the connection and create its ENIs. The
#     caller adds what the build itself needs (inline_policies).
#   - No inbound rules. The caller opens private endpoints to security_group_id, like modules/bastion.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  arn_prefix  = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}"
  eni_arn     = "${local.arn_prefix}:network-interface/*"
  subnet_arns = [for id in var.subnet_ids : "${local.arn_prefix}:subnet/${id}"]
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/codebuild/${var.name}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

data "aws_iam_policy_document" "this" {
  #checkov:skip=CKV_AWS_111:ec2 ENI create and delete must be on "*" for CodeBuild, see VpcEni below
  #checkov:skip=CKV_AWS_356:ec2 ENI create and delete must be on "*" for CodeBuild, see VpcEni below
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }
  statement {
    sid = "GitHubConnection"
    # Connections are created as codeconnections; CodeBuild may check either prefix.
    actions = [
      "codeconnections:GetConnection", "codeconnections:GetConnectionToken", "codeconnections:UseConnection",
      "codestar-connections:GetConnection", "codestar-connections:GetConnectionToken", "codestar-connections:UseConnection",
    ]
    resources = [var.connection_arn]
  }
  # Builds in a VPC: CodeBuild creates an ENI per build in these subnets with this SG.
  # Create and Delete must be on "*" (as in the AWS example policy): before a build leaves QUEUED,
  # CodeBuild checks them without a specific resource, so ARN-scoped grants fail with
  # UNAUTHORIZED_OPERATION_*_NETWORK_INTERFACE. The ENI permission stays scoped by its conditions.
  statement {
    sid = "VpcDescribe" # read-only, no resource-level permissions
    actions = [
      "ec2:DescribeNetworkInterfaces", "ec2:DescribeDhcpOptions", "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups", "ec2:DescribeVpcs",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "VpcEni"
    actions   = ["ec2:CreateNetworkInterface", "ec2:DeleteNetworkInterface"]
    resources = ["*"]
  }
  statement {
    sid       = "VpcEniPermission"
    actions   = ["ec2:CreateNetworkInterfacePermission"]
    resources = [local.eni_arn]
    condition {
      test     = "StringEquals"
      variable = "ec2:AuthorizedService"
      values   = ["codebuild.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "ec2:Subnet"
      values   = local.subnet_arns
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy" "this" {
  role   = aws_iam_role.this.id
  name   = "build"
  policy = data.aws_iam_policy_document.this.json
}

resource "aws_iam_role_policy" "extra" {
  for_each = var.inline_policies
  role     = aws_iam_role.this.id
  name     = each.key
  policy   = each.value
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-"
  description = "CodeBuild in the VPC: no inbound, HTTPS out"
  vpc_id      = var.vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

# GitHub, registries and AWS APIs (via NAT), and private endpoints in the VPC.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "HTTPS to GitHub, registries, AWS APIs and private endpoints"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_codebuild_project" "this" {
  name          = var.name
  description   = var.description
  service_role  = aws_iam_role.this.arn
  build_timeout = var.build_timeout

  source {
    type     = "GITHUB"
    location = "https://github.com/${var.github_repo}"
    auth {
      type     = "CODECONNECTIONS"
      resource = var.connection_arn
    }
    buildspec = var.buildspec
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type = var.compute_type
    image        = var.image
    type         = "LINUX_CONTAINER"
  }

  vpc_config {
    vpc_id             = var.vpc_id
    subnets            = var.subnet_ids
    security_group_ids = [aws_security_group.this.id]
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.this.name
    }
  }

  # CodeBuild checks the role's VPC permissions when the project is created.
  depends_on = [aws_iam_role_policy.this, aws_iam_role_policy.extra]
}
