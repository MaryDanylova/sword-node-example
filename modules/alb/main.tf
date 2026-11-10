# Public ALB in front of the EKS nodes: instance targets on the app's NodePort, attached to the
# node group's Auto Scaling groups, so nodes join and leave with the ASG (scaling, Spot).
#
# HTTP only by default. With https = true, port 443 terminates TLS with certificate_arn and port 80
# redirects to it.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

locals {
  https          = var.https ? 1 : 0
  client_ports   = var.https ? [80, 443] : [80]
  client_ingress = { for p in setproduct(var.allowed_cidrs, local.client_ports) : "${p[0]}:${p[1]}" => { cidr = p[0], port = p[1] } }
}

################################################################################
# Security groups: clients -> ALB :80 (and :443), ALB -> nodes :NodePort only
################################################################################

resource "aws_security_group" "lb" {
  name        = "${var.name}-alb"
  description = "App ALB"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "clients" {
  for_each = local.client_ingress

  security_group_id = aws_security_group.lb.id
  description       = "Port ${each.value.port} from clients"
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_egress_rule" "lb_to_nodes" {
  security_group_id            = aws_security_group.lb.id
  description                  = "To the app NodePort on the EKS nodes"
  ip_protocol                  = "tcp"
  from_port                    = var.node_port
  to_port                      = var.node_port
  referenced_security_group_id = var.node_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_lb" {
  security_group_id            = var.node_security_group_id
  description                  = "App NodePort from the ALB"
  ip_protocol                  = "tcp"
  from_port                    = var.node_port
  to_port                      = var.node_port
  referenced_security_group_id = aws_security_group.lb.id
}

################################################################################
# ALB -> target group (instance targets on the NodePort) -> node group ASGs
################################################################################

resource "aws_lb" "this" {
  name               = var.name
  load_balancer_type = "application"
  internal           = false
  subnets            = var.subnet_ids
  security_groups    = [aws_security_group.lb.id]

  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection
}

resource "aws_lb_target_group" "app" {
  name        = var.name
  vpc_id      = var.vpc_id
  target_type = "instance"
  protocol    = "HTTP"
  port        = var.node_port

  deregistration_delay = 30

  # externalTrafficPolicy=Local: a node answers on the NodePort only if it runs an app pod,
  # so the health check also takes nodes without a replica out of rotation (no extra hop).
  health_check {
    path                = var.health_path
    port                = "traffic-port"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Port 80: the app itself (HTTP only), or a redirect to 443 (https = true).
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = var.https ? "redirect" : "forward"
    target_group_arn = var.https ? null : aws_lb_target_group.app.arn

    dynamic "redirect" {
      for_each = var.https ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.https

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  lifecycle {
    precondition {
      condition     = var.certificate_arn != null
      error_message = "https = true needs certificate_arn."
    }
  }
}

# If the node group is ever recreated (new ASG name), re-apply the stack that uses this module.
resource "aws_autoscaling_attachment" "nodes" {
  for_each = toset(var.node_asg_names)

  autoscaling_group_name = each.value
  lb_target_group_arn    = aws_lb_target_group.app.arn
}
