output "dns_name" {
  value = aws_lb.this.dns_name
}

output "url" {
  value = "${var.https ? "https" : "http"}://${aws_lb.this.dns_name}/"
}

output "target_group_arn" {
  value = aws_lb_target_group.app.arn
}

output "security_group_id" {
  value = aws_security_group.lb.id
}
