output "project_name" {
  value = aws_codebuild_project.this.name
}

output "role_arn" {
  value = aws_iam_role.this.arn
}

output "security_group_id" {
  value = aws_security_group.this.id
}
