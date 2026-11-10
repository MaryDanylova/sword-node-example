variable "name" {
  description = "Globally unique bucket name."
  type        = string
}

variable "tags" {
  description = "Extra tags for the bucket (on top of the provider's default_tags)."
  type        = map(string)
  default     = {}
}

variable "force_destroy" {
  description = "Let `terraform destroy` delete a non-empty bucket (all objects and versions)."
  type        = bool
  default     = false
}

variable "versioning" {
  description = "Keep previous object versions (recover from overwrites and deletes)."
  type        = bool
  default     = false
}

variable "noncurrent_version_days" {
  description = "Expire noncurrent versions after N days (only when versioning = true)."
  type        = number
  default     = 30
}
