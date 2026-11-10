variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "region" {
  type = string
}

variable "state_bucket" {
  description = "Terraform state bucket, to read other stacks' outputs. Set by scripts/run-stack.sh (TF_VAR_state_bucket)."
  type        = string
}

variable "enable_lb" {
  description = "Create the ALB. false = remove it while keeping the stack and its state."
  type        = bool
  default     = true
}

variable "lb_allowed_cidrs" {
  description = "Client CIDRs allowed to reach the ALB on port 80 (and 443 with HTTPS)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "https_self_signed" {
  description = "Demo HTTPS: a self-signed certificate for the ALB's DNS name, imported into ACM; port 80 redirects to 443. Browsers warn about it (curl --cacert works). Production: an ACM-issued certificate for a real domain."
  type        = bool
  default     = false
}
