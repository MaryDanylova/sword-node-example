# access, every env. A copy of this repository (fork) changes these three values.
# Repository whose workflows may assume the CI roles:
# github_repo = "owner/repo"

# CI roles are created only in this account; a clone applied anywhere else gets none.
# An env in another account overrides it in envs/overlays/<env>/access.tfvars.
# github_aws_account_id = "123456789012"

# GitHub puts the immutable owner/repo IDs into the OIDC `sub` claim of this repository
# (gh api repos/<owner>/<repo> --jq '.owner.id, .id'). The plain form is kept as well.
# github_subject_prefixes = [
#   "repo:owner@owner-id/repo@repo-id",
#   "repo:owner/repo",
# ]
