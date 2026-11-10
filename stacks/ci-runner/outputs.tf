output "project_name" {
  description = "CodeBuild project scripts/py/codebuild.py starts, or null without CI."
  value       = try(module.build[0].project_name, null)
}
