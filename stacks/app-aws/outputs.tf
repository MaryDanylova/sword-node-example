output "app_namespace" {
  value = var.app_namespace
}

output "app_service_account" {
  value = var.app_service_account
}

output "app_role_arn" {
  value = aws_iam_role.app.arn
}

output "read_bucket" {
  description = "App may list + get."
  value       = module.read_bucket.id
}

output "write_bucket" {
  description = "App may put only."
  value       = module.write_bucket.id
}

output "queue_url" {
  description = "App may consume (receive/delete/change visibility)."
  value       = aws_sqs_queue.main.id
}

output "queue_arn" {
  value = aws_sqs_queue.main.arn
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.id
}

output "db_secret_arn" {
  description = "App DB secret the app role can read (null when database is down)."
  value       = local.user_secret.app
}

output "db_admin_namespace" {
  value = var.db_admin_namespace
}

output "db_admin_service_account" {
  value = var.db_admin_service_account
}

output "proxysql_namespace" {
  value = var.proxysql_namespace
}

output "proxysql_service_account" {
  value = var.proxysql_service_account
}
