output "lb_dns_name" {
  value = try(module.alb[0].dns_name, null)
}

output "app_url" {
  value = try(module.alb[0].url, null)
}

output "target_group_arn" {
  value = try(module.alb[0].target_group_arn, null)
}

output "self_signed_certificate_pem" {
  description = "With https_self_signed: the certificate to trust, e.g. curl --cacert <file> <app_url>."
  value       = try(tls_self_signed_cert.self_signed[0].cert_pem, null)
}
