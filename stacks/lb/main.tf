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

data "terraform_remote_state" "app_k8s" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "app-k8s.tfstate"
    region = var.region
  }
}

locals {
  net = data.terraform_remote_state.network.outputs
  eks = data.terraform_remote_state.eks.outputs
  app = data.terraform_remote_state.app_k8s.outputs

  self_signed = var.enable_lb && var.https_self_signed ? 1 : 0
}

module "alb" {
  source = "../../modules/alb"
  count  = var.enable_lb ? 1 : 0

  name                   = "${local.eks.cluster_name}-app"
  vpc_id                 = local.net.vpc_id
  subnet_ids             = local.net.public_subnet_ids
  allowed_cidrs          = var.lb_allowed_cidrs
  node_security_group_id = local.eks.node_security_group_id
  node_port              = local.app.node_port
  health_path            = local.app.health_path
  node_asg_names         = local.eks.node_asg_names
  deletion_protection    = var.deletion_protection

  https           = var.https_self_signed
  certificate_arn = one(aws_acm_certificate.self_signed[*].arn)
}

################################################################################
# Self-signed certificate (demo only): HTTPS without a domain. Browsers warn about it, the private
# key is in this stack's state, and ACM does not renew an imported certificate. Production uses an
# ACM-issued certificate for a real domain (DNS validation) and passes its ARN to modules/alb.
################################################################################

resource "tls_private_key" "self_signed" {
  count = local.self_signed

  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "self_signed" {
  count = local.self_signed

  private_key_pem       = tls_private_key.self_signed[0].private_key_pem
  validity_period_hours = 24 * 365
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
  dns_names             = [module.alb[0].dns_name] # the ALB's own name, so clients can verify it

  subject {
    common_name  = "${local.eks.cluster_name}-app (self-signed demo)"
    organization = var.project
  }
}

resource "aws_acm_certificate" "self_signed" {
  count = local.self_signed

  private_key      = tls_private_key.self_signed[0].private_key_pem
  certificate_body = tls_self_signed_cert.self_signed[0].cert_pem

  tags = { Name = "${local.eks.cluster_name}-app-self-signed" }

  lifecycle {
    create_before_destroy = true # the listener switches to the new one before the old one goes
  }
}
