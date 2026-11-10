variable "name" {
  description = "Name tag of the instance; scripts/tunnel.sh finds the bastion by it."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Private subnet for the bastion (needs NAT or SSM VPC endpoints for SSM)."
  type        = string
}

variable "instance_type" {
  type    = string
  default = "t4g.nano"
}

variable "architecture" {
  description = "arm64 for t4g, x86_64 for t3."
  type        = string
  default     = "arm64"
}
