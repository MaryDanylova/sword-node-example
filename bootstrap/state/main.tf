# One Terraform state bucket per environment: <project>-tfstate-<env>-<8 hex>.
# Found later by its tags (Project, Env from default_tags + Purpose), never by copying its name around.

# Bucket names are global across all AWS accounts; the random suffix keeps the name unique
# without exposing the account id.
resource "random_id" "suffix" {
  byte_length = 4
}

module "state_bucket" {
  source = "../../modules/s3-bucket"

  name = "${var.project}-tfstate-${var.env}-${random_id.suffix.hex}"
  tags = { Purpose = "tfstate" }

  versioning              = true
  noncurrent_version_days = var.noncurrent_version_days
  force_destroy           = false # only a deliberate `make clean` may ever delete state
}
