#!/usr/bin/env bash
# Create the Terraform state bucket of one environment (bootstrap/state), exactly once.
#
# Throwaway state (see tf_throwaway in lib.sh): the bucket is created, the state is deleted, and
# the bucket is found from then on by its tags (Project, Env, Purpose=tfstate). A second run stops
# on purpose when the bucket already exists - state buckets are never changed or destroyed here.
#
# Usage: scripts/state.sh <env> plan     preview (read-only)
#        scripts/state.sh <env> create   create the bucket (asks for confirmation)
. "$(dirname "$0")/lib.sh" "${1:-}"
ACTION="${2:-plan}"
[[ "$ACTION" == plan || "$ACTION" == create ]] || { echo "Usage: $0 <env> plan|create" >&2; exit 1; }

EXISTING="$(state_bucket_lookup)"
if [[ -n "$EXISTING" ]]; then
  echo "State bucket for '$ENV_NAME' already exists, nothing to do:" >&2
  echo "$EXISTING" | sed 's/^/  /' >&2
  exit 1
fi

export TF_VAR_env="$ENV_NAME"
VARFILES=()
while IFS= read -r f; do VARFILES+=("$f"); done < <(tfvar_files state)
tf_throwaway bootstrap/state "${ACTION/create/apply}" "${VARFILES[@]}"
