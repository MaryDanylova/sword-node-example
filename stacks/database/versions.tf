terraform {
  required_version = ">= 1.11" # write-only arguments (app secret)

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
      Stack     = "database"
      ManagedBy = "terraform"
    }
  }
}
