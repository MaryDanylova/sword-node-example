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

variable "kube_api_host" {
  description = "Where Terraform dials the Kubernetes API. Default = the SSM tunnel (`make tunnel`). null or \"\" = the private endpoint itself (inside the VPC: the ci-runner build sets \"\")."
  type        = string
  default     = "https://localhost:8443"
}

variable "assume_admin_role" {
  description = <<-EOT
    Talk to Kubernetes as <project>-<env>-admin (access), so your own AWS identity needs no cluster access.
    false = as the caller itself, when it is cluster-admin on its own: the CodeBuild role of ci-runner
    (its buildspec sets it).
  EOT
  type        = bool
  default     = true
}

################################################################################
# Workload
################################################################################

variable "image" {
  description = "App image. Pinned: the repository has no `latest` tag."
  type        = string
  default     = "swordhealth/node-example:0.0.1"
}

variable "replicas" {
  type    = number
  default = 2
}

variable "container_port" {
  type    = number
  default = 3000
}

variable "health_path" {
  description = "HTTP path for probes and the ALB health check (the app has no dedicated health endpoint)."
  type        = string
  default     = "/"
}

variable "node_port" {
  description = "Fixed NodePort the ALB target group points at (30000-32767)."
  type        = number
  default     = 30080

  validation {
    condition     = var.node_port >= 30000 && var.node_port <= 32767
    error_message = "node_port must be in the NodePort range 30000-32767."
  }
}

variable "resources" {
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "50m", memory = "64Mi" }
    limits   = { memory = "256Mi" }
  }
}

variable "aws_cli_image" {
  description = "Fetches the DB secrets for the app-user Job (has jq)."
  type        = string
  default     = "amazon/aws-cli:2.39.5"
}

variable "mysql_client_image" {
  description = "Runs the SQL of the app-user Job."
  type        = string
  default     = "mysql:8.4"
}

variable "proxysql_replicas" {
  description = "ProxySQL pods. 1 = a node drain or Spot interruption briefly cuts the DB connections; 2+ gets a PDB."
  type        = number
  default     = 1
}
