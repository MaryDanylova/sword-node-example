#!/usr/bin/env bash
# Run Terraform for one stack of one environment - the single place that knows how.
#   - state: the env's own bucket (found by tags, see bootstrap/state), key <stack>.tfstate
#   - inputs: layered tfvars, envs/base/ then envs/overlays/<env>/ (scripts/lib.sh layer_files)
#   - env:    the envs/overlays/<env>/ directory name (TF_VAR_env)
#
# Usage: scripts/run-stack.sh <env> <stack> plan|apply|destroy|import|output|state [extra terraform args]
#        (import and state: e.g. the state swap of scripts/py/db_restore.py)
#        (destroy outside dev needs CONFIRM=<env>)
#        (normally through make: make plan STACK=network ENV=dev)
. "$(dirname "$0")/lib.sh" "${1:-}"
STACK="${2:-}"
CMD="${3:-}"
shift $(($# < 3 ? $# : 3))

[[ -n "$STACK" ]] && in_list "$STACK" "${STACKS[@]}" || { echo "Unknown stack '$STACK' (have: ${STACKS[*]})" >&2; exit 1; }
case "$CMD" in plan | apply | destroy | import | output | state) ;; *) echo "Usage: $0 <env> <stack> plan|apply|destroy|import|output|state [args]" >&2; exit 1 ;; esac
# Also covers `make up ARGS=-destroy` (plan -destroy changes nothing, so it needs no confirm).
if [[ "$CMD" == destroy || ("$CMD" == apply && " $* " == *" -destroy "*) ]]; then require_destroy_confirm; fi

BUCKET="$(state_bucket)"
# Stacks read each other's outputs via terraform_remote_state; stacks that don't declare these ignore them.
export TF_VAR_env="$ENV_NAME" TF_VAR_state_bucket="$BUCKET"

TF=(terraform -chdir="$ROOT_DIR/stacks/$STACK")
# -reconfigure: the same stack dir is reused for different envs (different buckets).
# To stderr, so stdout is only the command's own output (make output ARGS='-raw x' > file).
"${TF[@]}" init -reconfigure -input=false \
  -backend-config="bucket=$BUCKET" -backend-config="region=$REGION" -backend-config="key=$STACK.tfstate" >&2

# output and state do not read the configuration, so no tfvars.
if [[ "$CMD" == output || "$CMD" == state ]]; then
  exec "${TF[@]}" "$CMD" "$@"
fi
VARFILES=()
while IFS= read -r f; do VARFILES+=("$f"); done < <(tfvar_files "$STACK")
exec "${TF[@]}" "$CMD" "${VARFILES[@]}" "$@"
