output "bucket" {
  description = "State bucket of this environment."
  value       = module.state_bucket.id
}
