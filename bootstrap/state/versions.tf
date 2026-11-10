terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Chicken-and-egg: this root creates the bucket every other state lives in, so its own
  # state is local and THROWN AWAY after the run (scripts/state.sh points `path` at a temp dir).
  # Nothing can destroy or modify the bucket through Terraform afterwards - on purpose.
  backend "local" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      Env       = var.env
      Stack     = "bootstrap-state"
      ManagedBy = "terraform"
    }
  }
}
