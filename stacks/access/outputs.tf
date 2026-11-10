# Read by eks: role names per Kubernetes access level.
output "cluster_admin_role_names" {
  description = "Roles granted cluster-admin. Not the CI apply role: CI deploys app-k8s from the CodeBuild project in stacks/ci-runner, whose own role ci-runner makes cluster-admin."
  value       = [module.admin.name]
}

output "cluster_viewer_role_names" {
  description = "Roles granted read-only access."
  value       = [module.viewer.name]
}

# Role ARNs to hand to people (CI derives its own, see scripts/ci-role.sh).
output "github_plan_role_arn" {
  value = try(module.github_plan[0].arn, null)
}

output "github_apply_role_arn" {
  value = try(module.github_apply[0].arn, null)
}

output "admin_role_arn" {
  value = module.admin.arn
}

output "viewer_role_arn" {
  value = module.viewer.arn
}

# Read by eks: the repository its CodeBuild runner serves (null = no CI roles, so no runner).
output "github_repo" {
  value = local.create_ci ? var.github_repo : null
}
