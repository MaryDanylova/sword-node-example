data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = "${var.project}-${var.env}"
  azs  = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /16 layout:
  #   private  /19 per AZ (10.0.0.0, .32, .64, .96...) - large, VPC CNI gives every pod a VPC IP
  #   public   /24 per AZ from 10.0.128.0               - ALB + NAT
  #   database /24 per AZ from 10.0.144.0               - RDS, no internet route needed
  private_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 3, i)]
  public_subnets   = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, 128 + i)]
  database_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, 144 + i)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets  = local.private_subnets
  public_subnets   = local.public_subnets
  database_subnets = local.database_subnets

  # Required for the EKS private endpoint to resolve inside the VPC.
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Egress for the private subnets (nodes pull images from Docker Hub).
  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  create_database_subnet_group       = true
  create_database_subnet_route_table = true # isolated: no default route at all

  map_public_ip_on_launch = false

  # Subnet discovery for load balancers (used if the AWS LB Controller is ever added).
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
    Tier                     = "public"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    Tier                              = "private"
  }
  database_subnet_tags = {
    Tier = "database"
  }
}

# Free gateway endpoint: S3 traffic (app buckets, ECR image layers) skips the NAT.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = {
    Name = "${local.name}-s3"
  }
}
