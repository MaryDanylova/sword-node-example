# ProxySQL in front of the MySQL instance: apps connect to a stable in-cluster address
# (<name>.<namespace>.svc:6033) with their own MySQL user, and ProxySQL holds the backend.
# The backend can be switched at runtime (admin interface, 127.0.0.1:6032 inside the pod):
# reboots, failovers and restores reach the apps as backend reconnects, not as restarts.
#
# No password in Kubernetes: an init container reads the user secrets (Pod Identity) and renders
# proxysql.cnf into a memory-backed volume. The backend address comes from a ConfigMap, so a
# cutover can update it at once and a pod started later still points at the current instance.

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.0"
    }
  }
}

locals {
  labels = {
    "app.kubernetes.io/name"      = var.name
    "app.kubernetes.io/component" = "mysql-proxy"
  }
  port = 6033

  render_script = templatefile("${path.module}/scripts/render-config.sh.tftpl", {
    port                    = local.port
    backend_max_connections = var.backend_max_connections
  })
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

# Bound to the proxysql AWS role (read the app and monitor secrets) by a Pod Identity association.
resource "kubernetes_service_account_v1" "this" {
  metadata {
    name      = var.service_account
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.labels
  }
}

# The current backend. Terraform sets it from the database stack; a cutover patches it right after
# switching the running pods, so a pod (re)started before the next apply gets the same backend.
resource "kubernetes_config_map_v1" "backend" {
  metadata {
    name      = "${var.name}-backend"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.labels
  }
  data = {
    BACKEND_HOST = var.backend_host
    BACKEND_PORT = tostring(var.backend_port)
  }
}

resource "kubernetes_deployment_v1" "this" {
  metadata {
    name      = var.name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.labels
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
        annotations = {
          # Roll the pods when the rendered config changes shape. Not on a backend change: that
          # is switched at runtime, without dropping the apps' connections.
          "checksum/render" = sha256(local.render_script)
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.this.metadata[0].name

        security_context {
          run_as_non_root = true
          run_as_user     = 999 # the image's proxysql user
          run_as_group    = 999
          fs_group        = 999
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = local.labels
          }
        }

        init_container {
          name    = "render-config"
          image   = var.aws_cli_image
          command = ["sh", "-c", local.render_script]

          env {
            name  = "AWS_REGION"
            value = var.region
          }
          env {
            name  = "HOME"
            value = "/tmp"
          }
          env {
            name  = "APP_SECRET_ARN"
            value = var.app_secret_arn
          }
          env {
            name  = "MONITOR_SECRET_ARN"
            value = var.monitor_secret_arn
          }
          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.backend.metadata[0].name
            }
          }

          security_context {
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        container {
          name = "proxysql"
          # -f: foreground. The datadir starts empty in every new pod, so the rendered file applies;
          # after a cutover the switch is also saved there (SAVE ... TO DISK), so a container
          # restart inside the same pod keeps it.
          image   = var.image
          command = ["proxysql", "-f", "-c", "/config/proxysql.cnf", "-D", "/var/lib/proxysql"]

          port {
            name           = "mysql"
            container_port = local.port
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          readiness_probe {
            tcp_socket {
              port = "mysql"
            }
            period_seconds = 5
          }
          liveness_probe {
            tcp_socket {
              port = "mysql"
            }
            initial_delay_seconds = 10
            period_seconds        = 20
          }

          security_context {
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
            read_only  = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/proxysql"
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        # Both memory-backed, so no password reaches the node's disk: /config holds the rendered
        # file, and ProxySQL copies the users (with passwords) and its TLS key into its SQLite
        # database in the data directory. Both live as long as the pod (a container restart keeps
        # a cutover saved there); a new pod renders again from the secrets and the ConfigMap.
        volume {
          name = "config"
          empty_dir {
            medium     = "Memory"
            size_limit = "1Mi"
          }
        }
        volume {
          name = "data"
          empty_dir {
            medium     = "Memory"
            size_limit = "64Mi" # proxysql.db + stats, well under 1 MB; counts toward the memory limit
          }
        }
        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }

  lifecycle {
    # Set by kubectl rollout restart. Removing it would roll the pods again on the next apply.
    ignore_changes = [spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"]]
  }
}

resource "kubernetes_pod_disruption_budget_v1" "this" {
  count = var.replicas > 1 ? 1 : 0

  metadata {
    name      = var.name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.labels
  }
  spec {
    min_available = 1
    selector {
      match_labels = local.labels
    }
  }
}

resource "kubernetes_service_v1" "this" {
  metadata {
    name      = var.name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.labels
  }
  spec {
    selector = local.labels
    port {
      name        = "mysql"
      port        = local.port
      target_port = "mysql"
    }
  }
}

################################################################################
# Only the client namespaces may connect (6033); the admin interface is not on the network at all.
################################################################################

resource "kubernetes_network_policy_v1" "default_deny_ingress" {
  metadata {
    name      = "default-deny-ingress"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy_v1" "allow_clients" {
  metadata {
    name      = "allow-mysql-clients"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = local.labels
    }
    policy_types = ["Ingress"]

    ingress {
      dynamic "from" {
        for_each = var.client_namespaces
        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.value }
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = tostring(local.port)
      }
    }
  }
}
