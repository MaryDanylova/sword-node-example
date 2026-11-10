deletion_protection = true
# lb_allowed_cidrs stays open only because the app is a public demo; restrict it or front with CloudFront/WAF.
# HTTPS: a real deployment uses an ACM-issued certificate for its domain (modules/alb certificate_arn),
# never a self-signed one; with no domain here, prod stays on HTTP.
https_self_signed = false
