variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_cidr" {
  description = "VPC CIDR. Must be at least a /16 for the default subnet layout."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones (EKS needs at least 2)."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

variable "single_nat_gateway" {
  description = "One shared NAT Gateway (cheaper) instead of one per AZ (an AZ outage does not cut the others' egress)."
  type        = bool
  default     = true
}

