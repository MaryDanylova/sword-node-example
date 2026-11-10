output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Private API endpoint (resolves to VPC IPs; reach it via the SSM tunnel)."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "cluster_version" {
  value = module.eks.cluster_version
}

output "cluster_security_group_id" {
  description = "Security group on the control-plane ENIs (bastion gets 443 into it)."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group on nodes (and pods). Used by RDS and ALB rules."
  value       = module.eks.node_security_group_id
}

output "node_asg_names" {
  description = "Auto Scaling groups behind the managed node group (ALB target group attachment)."
  value       = module.eks.eks_managed_node_groups_autoscaling_group_names
}

output "node_iam_role_name" {
  value = module.eks.node_iam_role_name
}

output "oidc_provider_arn" {
  description = "Cluster OIDC provider (only needed if IRSA is used instead of Pod Identity)."
  value       = module.eks.oidc_provider_arn
}

output "bastion_instance_id" {
  value = try(module.bastion[0].instance_id, null)
}
