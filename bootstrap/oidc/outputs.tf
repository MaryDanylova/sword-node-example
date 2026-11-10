output "arn" {
  description = "ARN of the OIDC provider (the roles stack finds it by URL, no need to copy it)."
  value       = aws_iam_openid_connect_provider.github.arn
}
