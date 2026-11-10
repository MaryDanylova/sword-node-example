variable "name" {
  description = "Deployment, Service and label name."
  type        = string
  default     = "proxysql"
}

variable "namespace" {
  description = "Created by this module (restricted Pod Security)."
  type        = string
}

variable "service_account" {
  description = "Must match the Pod Identity association of the role that reads the user secrets."
  type        = string
}

variable "region" {
  type = string
}

variable "replicas" {
  description = "1 is enough for a demo; 2+ (with a PDB) so a node drain or Spot interruption does not cut every DB connection."
  type        = number
  default     = 1
}

variable "image" {
  type    = string
  default = "proxysql/proxysql:3.0.11"
}

variable "aws_cli_image" {
  description = "Renders the config (needs aws, jq, curl)."
  type        = string
  default     = "amazon/aws-cli:2.39.5"
}

variable "backend_host" {
  description = "MySQL endpoint ProxySQL starts with (RDS address)."
  type        = string
}

variable "backend_port" {
  type    = number
  default = 3306
}

variable "backend_max_connections" {
  description = "Connections ProxySQL opens to the backend, per pod (keep the sum below the instance's max_connections)."
  type        = number
  default     = 50
}

variable "app_secret_arn" {
  description = "Secret (JSON: username, password) of the MySQL user the clients log in as."
  type        = string
}

variable "monitor_secret_arn" {
  description = "Secret of the MySQL user ProxySQL health-checks the backend with (USAGE only)."
  type        = string
}

variable "client_namespaces" {
  description = "Namespaces whose pods may connect on 6033."
  type        = list(string)
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
