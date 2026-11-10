output "host" {
  description = "What clients connect to."
  value       = "${kubernetes_service_v1.this.metadata[0].name}.${kubernetes_namespace_v1.this.metadata[0].name}.svc"
}

output "port" {
  value = local.port
}

output "namespace" {
  value = kubernetes_namespace_v1.this.metadata[0].name
}

output "selector" {
  description = "Labels of the ProxySQL pods (for kubectl exec into each one at a cutover)."
  value       = local.labels
}

output "backend_config_map" {
  value = kubernetes_config_map_v1.backend.metadata[0].name
}
