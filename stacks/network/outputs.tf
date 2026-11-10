# Consumed by later stacks via terraform_remote_state.

output "name" {
  description = "<project>-<env> naming prefix."
  value       = local.name
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr_block
}

output "azs" {
  value = local.azs
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "private_subnet_cidrs" {
  value = module.vpc.private_subnets_cidr_blocks
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "public_subnet_cidrs" {
  description = "Where the ALB lives; used by the app NetworkPolicy allow-list."
  value       = module.vpc.public_subnets_cidr_blocks
}

output "database_subnet_ids" {
  value = module.vpc.database_subnets
}

output "database_subnet_group_name" {
  value = module.vpc.database_subnet_group_name
}

output "private_route_table_ids" {
  value = module.vpc.private_route_table_ids
}

output "nat_public_ips" {
  description = "Egress IPs of the cluster (NAT Gateway EIPs)."
  value       = module.vpc.nat_public_ips
}
