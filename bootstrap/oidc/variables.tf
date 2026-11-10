variable "region" {
  description = "Region of the AWS API endpoint (IAM itself is global). Passed by scripts/oidc.sh from envs/base/common.tfvars."
  type        = string
}

variable "url" {
  description = "OIDC issuer. github.com: https://token.actions.githubusercontent.com ; GitHub Enterprise Server: https://<HOST>/_services/token"
  type        = string
  default     = "https://token.actions.githubusercontent.com"
}

variable "thumbprints" {
  description = "TLS thumbprints of the issuer. Not needed for github.com (AWS trusts its CA); may be needed for GitHub Enterprise Server."
  type        = list(string)
  default     = []
}
