#!/usr/bin/env bash
# Declare a new environment: creates envs/overlays/<env>/common.tfvars, the file every script and workflow
# checks before working with an env (so a typo like ENV=dve fails instead of getting the base config).
# Local only, no AWS calls. The new env starts as the base config (envs/base/) as is.
#
# Usage: scripts/init-env.sh <env>     (make init-env ENV=<env>)
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_NAME="${1:-}"

# Same rule as bootstrap/state: the name is part of S3 bucket and IAM role names.
[[ "$ENV_NAME" =~ ^[a-z0-9-]{1,20}$ ]] || { echo "Usage: $0 <env>  (1-20 lower-case letters, digits or '-')" >&2; exit 1; }
FILE="$ROOT_DIR/envs/overlays/$ENV_NAME/common.tfvars"
[[ ! -e "$FILE" ]] || { echo "Env '$ENV_NAME' already exists: envs/overlays/$ENV_NAME/" >&2; exit 1; }

mkdir -p "$(dirname "$FILE")"
cat >"$FILE" <<TFVARS
# $ENV_NAME = the base config (envs/base/) as is. Add a file here only for what $ENV_NAME changes.
TFVARS

cat <<MSG
Created envs/overlays/$ENV_NAME/common.tfvars. Next:
  1. Overrides (optional): envs/overlays/$ENV_NAME/<stack>.tfvars with only what differs from envs/base/
     (e.g. vpc_cidr in network.tfvars if $ENV_NAME may ever be peered with another env).
  2. make state ENV=$ENV_NAME                  # its state bucket   } needed before the PR: ci.yml plans
  3. make access ENV=$ENV_NAME                 # its roles          } every env and fails without them
  4. Pull request; then make up-all ENV=$ENV_NAME (everything else), or apply.yml once the
     GitHub Environment "$ENV_NAME" exists.
MSG
