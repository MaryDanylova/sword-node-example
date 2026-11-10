variable "name" {
  description = "Name of the ALB and its target group (max 32 characters); the SG is <name>-alb."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Public subnets, in at least two AZs (an ALB requirement)."
  type        = list(string)
}

variable "allowed_cidrs" {
  description = "Client CIDRs allowed on port 80 (and 443 with https)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_security_group_id" {
  description = "SG of the EKS nodes; gets an ingress rule for the NodePort from the ALB."
  type        = string
}

variable "node_port" {
  type = number
}

variable "health_path" {
  type    = string
  default = "/"
}

variable "node_asg_names" {
  description = "Auto Scaling groups of the node group(s); their instances become the targets."
  type        = list(string)
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "https" {
  description = "true = TLS on 443 with certificate_arn, and port 80 redirects to it. A plain bool, so it is known at plan time even when the certificate is created in the same apply."
  type        = bool
  default     = false
}

variable "certificate_arn" {
  description = "ACM certificate for the HTTPS listener (with https = true)."
  type        = string
  default     = null
}

variable "ssl_policy" {
  description = "TLS 1.3 with TLS 1.2 as the minimum."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}
