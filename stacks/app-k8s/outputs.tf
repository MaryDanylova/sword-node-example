output "namespace" {
  value = kubernetes_namespace_v1.app.metadata[0].name
}

output "service_account" {
  value = kubernetes_service_account_v1.app.metadata[0].name
}

output "service_name" {
  value = kubernetes_service_v1.app.metadata[0].name
}

output "node_port" {
  description = "ALB target group port (lb)."
  value       = var.node_port
}

output "health_path" {
  description = "ALB health check path (lb)."
  value       = var.health_path
}

output "proxysql" {
  description = "Where apps connect, and how to find the ProxySQL pods (cutover)."
  value = {
    host               = module.proxysql.host
    port               = module.proxysql.port
    namespace          = module.proxysql.namespace
    selector           = module.proxysql.selector
    backend_config_map = module.proxysql.backend_config_map
  }
}
