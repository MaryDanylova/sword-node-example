terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Run-once root with a THROWAWAY local state (scripts/oidc.sh points `path` at a temp dir).
  # The provider is shared by every repo and project in the account, so nothing here may
  # ever change or destroy it.
  backend "local" {}
}

provider "aws" {
  region = var.region # IAM is global; the provider still needs a region for its API endpoint

  # No Project tag on purpose: the provider belongs to the account, not to this project.
  default_tags {
    tags = {
      Stack     = "bootstrap-oidc"
      ManagedBy = "terraform"
    }
  }
}
