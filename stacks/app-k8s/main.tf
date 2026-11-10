data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "network.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "eks.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "database" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "database.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "app_aws" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "app-aws.tfstate"
    region = var.region
  }
}

# Kubernetes access goes through the env's admin role (see access).
data "terraform_remote_state" "access" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "access.tfstate"
    region = var.region
  }
}

locals {
  net = data.terraform_remote_state.network.outputs
  eks = data.terraform_remote_state.eks.outputs
  db  = data.terraform_remote_state.database.outputs
  aws = data.terraform_remote_state.app_aws.outputs

  endpoint_host = trimprefix(local.eks.cluster_endpoint, "https://")
  kube_host     = coalesce(var.kube_api_host, local.eks.cluster_endpoint)
  # Token for the admin role, unless the caller is cluster-admin itself (the CI apply role).
  kube_role_args = var.assume_admin_role ? ["--role-arn", data.terraform_remote_state.access.outputs.admin_role_arn] : []

  # Namespace / SA names come from app-aws, so the Pod Identity association always matches.
  namespace = local.aws.app_namespace
  sa        = local.aws.app_service_account
  app       = "node-example"
  labels = {
    "app.kubernetes.io/name"    = local.app
    "app.kubernetes.io/part-of" = var.project
  }
}

################################################################################
# Namespace + identity
################################################################################

resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = local.namespace
    labels = {
      # Restricted Pod Security Standard: the pod spec below must stay non-root, no privilege escalation, etc.
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

# Bound to the AWS role by the Pod Identity association in app-aws (no annotation needed).
resource "kubernetes_service_account_v1" "app" {
  metadata {
    name      = local.sa
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels    = local.labels
  }
}

################################################################################
# Bonus: the app may list pods in kube-system (namespace-scoped Role, not a ClusterRole)
################################################################################

resource "kubernetes_role_v1" "kube_system_pod_reader" {
  metadata {
    name      = "${local.app}-pod-reader"
    namespace = "kube-system"
    labels    = local.labels
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding_v1" "kube_system_pod_reader" {
  metadata {
    name      = "${local.app}-pod-reader"
    namespace = "kube-system"
    labels    = local.labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.kube_system_pod_reader.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.app.metadata[0].name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
}

################################################################################
# Config. No DB password here: the app's own MySQL user (not the master one) is in Secrets
# Manager, and the pod's AWS role may read DB_SECRET_ARN - never in Terraform state or a k8s Secret.
# DB_HOST is ProxySQL, so a DB restart, failover or restore never changes the app's config.
################################################################################

resource "kubernetes_config_map_v1" "app" {
  metadata {
    name      = local.app
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels    = local.labels
  }
  data = {
    AWS_REGION    = var.region
    READ_BUCKET   = local.aws.read_bucket
    WRITE_BUCKET  = local.aws.write_bucket
    QUEUE_URL     = local.aws.queue_url
    DB_HOST       = module.proxysql.host
    DB_PORT       = tostring(module.proxysql.port)
    DB_NAME       = local.db.db_name
    DB_SECRET_ARN = local.db_users.app.secret_arn
  }
}

################################################################################
# Workload
################################################################################

resource "kubernetes_deployment_v1" "app" {
  metadata {
    name      = local.app
    namespace = kubernetes_namespace_v1.app.metadata[0].name
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
          # Roll the pods when the config changes.
          "checksum/config" = sha256(jsonencode(kubernetes_config_map_v1.app.data))
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.app.metadata[0].name

        security_context {
          run_as_non_root = true
          run_as_user     = 1001
          run_as_group    = 1001
          fs_group        = 1001
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        # Spread replicas over nodes: with externalTrafficPolicy=Local each node serves only its own pods.
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = local.labels
          }
        }

        # The image compiles .less into public/ at runtime. Root FS is read-only, so copy
        # public/ into a writable emptyDir first.
        init_container {
          name    = "copy-public"
          image   = var.image
          command = ["sh", "-c", "cp -r /app/public/. /work/"]
          security_context {
            # Set explicitly: the provider otherwise sends runAsNonRoot=false per container,
            # overriding the pod-level value and failing the restricted Pod Security check.
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
          volume_mount {
            name       = "public"
            mount_path = "/work"
          }
        }

        container {
          name  = local.app
          image = var.image

          port {
            name           = "http"
            container_port = var.container_port
          }

          env {
            name  = "PORT"
            value = tostring(var.container_port)
          }
          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.app.metadata[0].name
            }
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          readiness_probe {
            http_get {
              path = var.health_path
              port = "http"
            }
            period_seconds = 10
          }
          liveness_probe {
            http_get {
              path = var.health_path
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 20
          }

          security_context {
            # Set explicitly: the provider otherwise sends runAsNonRoot=false per container,
            # overriding the pod-level value and failing the restricted Pod Security check.
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "public"
            mount_path = "/app/public"
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        volume {
          name = "public"
          empty_dir {}
        }
        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "app" {
  metadata {
    name      = local.app
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels    = local.labels
  }
  spec {
    min_available = 1
    selector {
      match_labels = local.labels
    }
  }
}

# Fixed NodePort for the ALB (lb). externalTrafficPolicy=Local: kube-proxy does not SNAT,
# so pods see the ALB's own IP - which is what the NetworkPolicy below allows.
resource "kubernetes_service_v1" "app" {
  metadata {
    name      = local.app
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels    = local.labels
  }
  spec {
    type                    = "NodePort"
    external_traffic_policy = "Local"
    selector                = local.labels

    port {
      name        = "http"
      port        = 80
      target_port = "http"
      node_port   = var.node_port
    }
  }
}

################################################################################
# Network isolation: no pod may reach the app. Only the ALB (public subnets) gets in.
################################################################################

resource "kubernetes_network_policy_v1" "default_deny_ingress" {
  metadata {
    name      = "default-deny-ingress"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

# Pods live in the private subnets, the ALB ENIs in the public ones - so allowing only the
# public subnet CIDRs lets the load balancer in and keeps every pod (any namespace) out.
resource "kubernetes_network_policy_v1" "allow_from_lb" {
  metadata {
    name      = "allow-from-load-balancer"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = local.labels
    }
    policy_types = ["Ingress"]

    ingress {
      dynamic "from" {
        for_each = local.net.public_subnet_cidrs
        content {
          ip_block {
            cidr = from.value
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = tostring(var.container_port)
      }
    }
  }
}

################################################################################
# MySQL users: a Job logs in as master and creates each user, or resets its password to its secret
# (database): app (privileges on the app database only) and monitor (USAGE, for ProxySQL).
# Idempotent, so it also re-syncs after a snapshot restore (the data brings the users back with
# their older passwords). Runs in its own namespace: no app namespace sees master credentials.
################################################################################

locals {
  db_users = local.db.db_user_secrets

  db_user_script = file("${path.module}/scripts/db-users.sh")

  # A new Job (new name) when a password, the instance or the script changes; otherwise none.
  db_user_job = "db-users-${substr(sha1(join(",", concat(
    [for k in sort(keys(local.db_users)) : local.db_users[k].version_id],
    [local.db.db_resource_id, local.db_user_script],
  ))), 0, 8)}"
}

resource "kubernetes_namespace_v1" "db_admin" {
  metadata {
    name = local.aws.db_admin_namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

# Bound to the db-admin AWS role by the Pod Identity association in app-aws.
resource "kubernetes_service_account_v1" "db_admin" {
  metadata {
    name      = local.aws.db_admin_service_account
    namespace = kubernetes_namespace_v1.db_admin.metadata[0].name
  }
}

resource "kubernetes_network_policy_v1" "db_admin_deny_ingress" {
  metadata {
    name      = "default-deny-ingress"
    namespace = kubernetes_namespace_v1.db_admin.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_job_v1" "db_users" {
  metadata {
    name      = local.db_user_job
    namespace = kubernetes_namespace_v1.db_admin.metadata[0].name
  }

  spec {
    backoff_limit           = 4 # a just-created instance may still refuse the first connections
    active_deadline_seconds = 600

    template {
      metadata {}
      spec {
        restart_policy       = "Never"
        service_account_name = kubernetes_service_account_v1.db_admin.metadata[0].name

        security_context {
          run_as_non_root = true
          run_as_user     = 999
          run_as_group    = 999
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        # Fetch the secrets (Pod Identity) into a memory-backed volume: never in the pod spec,
        # a k8s Secret or the process list.
        init_container {
          name    = "fetch-secrets"
          image   = var.aws_cli_image
          command = ["sh", "-c", file("${path.module}/scripts/fetch-secrets.sh")]
          env {
            name  = "AWS_REGION"
            value = var.region
          }
          env {
            name  = "HOME"
            value = "/tmp"
          }
          env {
            name  = "MASTER_SECRET_ARN"
            value = local.db.db_master_secret_arn
          }
          env {
            name  = "APP_SECRET_ARN"
            value = local.db_users.app.secret_arn
          }
          env {
            name  = "MONITOR_SECRET_ARN"
            value = local.db_users.monitor.secret_arn
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
            name       = "creds"
            mount_path = "/creds"
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        container {
          name    = "create-user"
          image   = var.mysql_client_image
          command = ["sh", "-c", local.db_user_script]
          env {
            name  = "DB_HOST"
            value = local.db.db_address
          }
          env {
            name  = "DB_PORT"
            value = tostring(local.db.db_port)
          }
          env {
            name  = "DB_NAME"
            value = local.db.db_name
          }
          env {
            name  = "HOME"
            value = "/tmp"
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
            name       = "creds"
            mount_path = "/creds"
            read_only  = true
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        volume {
          name = "creds"
          empty_dir {
            medium = "Memory"
          }
        }
        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }

  # The apply fails if the user cannot be created, instead of a silently broken app config.
  wait_for_completion = true
  timeouts {
    create = "10m"
    update = "10m"
  }
}

################################################################################
# ProxySQL: the apps' only way to MySQL (modules/proxysql). Its backend can be switched at runtime,
# so DB restarts, failovers and restores do not restart the apps.
################################################################################

module "proxysql" {
  source = "../../modules/proxysql"

  namespace          = local.aws.proxysql_namespace
  service_account    = local.aws.proxysql_service_account
  region             = var.region
  replicas           = var.proxysql_replicas
  backend_host       = local.db.db_address
  backend_port       = local.db.db_port
  app_secret_arn     = local.db_users.app.secret_arn
  monitor_secret_arn = local.db_users.monitor.secret_arn
  client_namespaces  = [kubernetes_namespace_v1.app.metadata[0].name]

  # The users must exist before ProxySQL logs in with them.
  depends_on = [kubernetes_job_v1.db_users]
}
