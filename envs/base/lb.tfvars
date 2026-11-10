# Base (every env): the ALB is on. To remove it from one env, set enable_lb = false in
# envs/overlays/<env>/lb.tfvars and make up STACK=lb.
enable_lb = true

# HTTPS with a self-signed certificate for the ALB's own DNS name: there is no domain here. Browsers
# warn about it; port 80 redirects to 443.
https_self_signed = true
