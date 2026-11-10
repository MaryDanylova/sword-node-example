terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }

  # bucket, region and key (<stack>.tfstate) are passed by scripts/run-stack.sh: one state bucket per env.
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      Env       = var.env
      Stack     = "app-k8s"
      ManagedBy = "terraform"
    }
  }
}

# The API endpoint is private. From a laptop Terraform goes through the SSM tunnel
# (`make tunnel`), so it dials localhost but validates the cert for the real endpoint host.
# Inside the VPC (the ci-runner CodeBuild build) kube_api_host = "" dials the endpoint directly.
provider "kubernetes" {
  host                   = local.kube_host
  tls_server_name        = local.endpoint_host
  cluster_ca_certificate = base64decode(local.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = concat(["eks", "get-token", "--cluster-name", local.eks.cluster_name, "--region", var.region], local.kube_role_args)
  }
}
