#!/usr/bin/env bash
# CI helper: which AWS role and region a workflow uses for an env - derived from the repo, no
# GitHub variables needed. Roles have fixed names (stacks/access); the account is
# github_aws_account_id from the tfvars layers (envs/base/access.tfvars, overridable per env).
#
# Usage: scripts/ci-role.sh <env> plan|apply   prints role_arn=... and region=... (for $GITHUB_OUTPUT)
. "$(dirname "$0")/lib.sh" "${1:-}"
KIND="${2:-}"
[[ "$KIND" == plan || "$KIND" == apply ]] || { echo "Usage: $0 <env> plan|apply" >&2; exit 1; }

ACCOUNT="$(tfvar github_aws_account_id access)"
[[ -n "$ACCOUNT" ]] || { echo "::error::github_aws_account_id is not set (envs/base/access.tfvars)" >&2; exit 1; }

echo "role_arn=arn:aws:iam::$ACCOUNT:role/$PROJECT-$ENV_NAME-github-$KIND"
echo "region=$REGION"
