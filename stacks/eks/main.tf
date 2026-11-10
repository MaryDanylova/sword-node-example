data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "network.tfstate"
    region = var.region
  }
}

# Who may use the cluster: role names from access, plus extra roles managed elsewhere (e.g. SSO).
data "terraform_remote_state" "access" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "access.tfstate"
    region = var.region
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  net    = data.terraform_remote_state.network.outputs
  access = data.terraform_remote_state.access.outputs
  name   = local.net.name

  # Kubernetes access level -> EKS access policy and the role names that get it.
  access_levels = {
    admin = {
      policy = "AmazonEKSClusterAdminPolicy"
      roles  = concat(local.access.cluster_admin_role_names, var.extra_admin_role_names)
    }
    view = {
      policy = "AmazonEKSViewPolicy"
      roles  = concat(local.access.cluster_viewer_role_names, var.extra_viewer_role_names)
    }
  }

  # One access entry per role name; the ARN is built from the current account (no account id in git).
  access_entries = merge([
    for level, l in local.access_levels : {
      for n in distinct(l.roles) : n => {
        principal_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${n}"
        policy_associations = {
          (level) = {
            policy_arn   = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/${l.policy}"
            access_scope = { type = "cluster" }
          }
        }
      }
    }
  ]...)
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  # Private API: reachable only from inside the VPC (bastion / SSM tunnel).
  endpoint_private_access      = true
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access ? var.endpoint_public_access_cidrs : null

  # Access entries (EKS API) instead of the deprecated aws-auth ConfigMap.
  authentication_mode = "API"
  # Nobody is admin just for having created the cluster: access is explicit (access roles).
  enable_cluster_creator_admin_permissions = false
  access_entries                           = local.access_entries

  # A fixed key admin: by default it is whoever applied last, so the policy flips between CI and local.
  kms_key_administrators = [local.access.admin_role_arn]

  vpc_id                   = local.net.vpc_id
  subnet_ids               = local.net.private_subnet_ids
  control_plane_subnet_ids = local.net.private_subnet_ids

  enabled_log_types                      = var.log_types
  cloudwatch_log_group_retention_in_days = var.log_retention_days

  addons = {
    vpc-cni = {
      before_compute = true
      # Native NetworkPolicy enforcement (eBPF node agent) - no Calico needed.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      capacity_type  = var.node_capacity_type
      instance_types = var.node_instance_types

      # No autoscaler: the group stays at min. The module sets desired_size once and then
      # ignores it (an autoscaler would own it), so raising min_size later above the current
      # size is rejected by EKS; scale with the AWS CLI first or recreate the stack.
      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_min_size

      subnet_ids = local.net.private_subnet_ids

      labels = {
        workload = "general"
      }
    }
  }
}

################################################################################
# Access: SSM bastion -> private EKS endpoint (scripts/tunnel.sh)
################################################################################

module "bastion" {
  source = "../../modules/bastion"
  count  = var.enable_bastion ? 1 : 0

  name          = "${local.name}-bastion"
  vpc_id        = local.net.vpc_id
  subnet_id     = local.net.private_subnet_ids[0]
  instance_type = var.bastion_instance_type
}

resource "aws_vpc_security_group_ingress_rule" "cluster_from_bastion" {
  count = var.enable_bastion ? 1 : 0

  security_group_id            = module.eks.cluster_security_group_id
  description                  = "EKS API from the SSM bastion (port-forward tunnel)"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = module.bastion[0].security_group_id
}
