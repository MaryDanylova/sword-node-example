# Shared helpers for scripts/*. Source it: `. "$(dirname "$0")/lib.sh" "<env>"`,
# or `. lib.sh --account` for account-wide scripts (base layer only, no env).
# Reads project/region from the same layered tfvars as Terraform (see layer_files).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="$ROOT_DIR/envs/base"
if [[ "${1:-}" == --account ]]; then
  ENV_NAME=""
  OVERLAY_DIR=""
else
  ENV_NAME="${1:-${ENV:-dev}}"
  OVERLAY_DIR="$ROOT_DIR/envs/overlays/$ENV_NAME"
  [[ -f "$OVERLAY_DIR/common.tfvars" ]] || { echo "Unknown env '$ENV_NAME' (no envs/overlays/$ENV_NAME/common.tfvars). Declare it: make init-env ENV=$ENV_NAME" >&2; exit 1; }
fi

# Stacks in dependency order: each one may read (terraform_remote_state) only stacks listed before it
# (checked by scripts/check-stacks.sh in make validate). down goes in reverse.
STACKS=(access network eks ci-runner database app-aws app-k8s lb)
# Applied by a person (or apply.yml naming it), never by up-all/down-all: it holds the roles,
# including the one CI applies with, so destroying it from CI would lock CI out.
HUMAN_ONLY=(access)
in_list() { # <item> <list...>
  local x="$1"; shift
  [[ " $* " == *" $x "* ]]
}

# The stacks a stack reads through terraform_remote_state.
stack_upstreams() { # <stack>
  sed -nE 's/^ *key *= *"([a-z0-9-]+)\.tfstate".*/\1/p' "$ROOT_DIR/stacks/$1"/*.tf | sort -u
}

# The tfvars files of a stack (or, without one, of every stack), in layer order (later wins) - whichever exist:
#   envs/base/common.tfvars               every stack, every env
#   envs/base/<stack>.tfvars              this stack, every env
#   envs/overlays/<env>/common.tfvars     every stack, this env
#   envs/overlays/<env>/<stack>.tfvars    this stack, this env
layer_files() { # [stack, e.g. network or state]
  local f
  for f in "$BASE_DIR/common.tfvars" ${1:+"$BASE_DIR/$1.tfvars"} \
    ${OVERLAY_DIR:+"$OVERLAY_DIR/common.tfvars"} ${OVERLAY_DIR:+${1:+"$OVERLAY_DIR/$1.tfvars"}}; do
    [[ -f "$f" ]] && echo "$f"
  done
  return 0
}

# -var-file arguments for Terraform, same order.
tfvar_files() { # <stack>
  layer_files "$1" | sed 's/^/-var-file=/'
}

# Value of a string variable across the layers; the last layer that sets it wins.
tfvar() { # <variable> [stack]
  local f files=()
  while IFS= read -r f; do files+=("$f"); done < <(layer_files "${2:-}")
  sed -n "s/^$1 *= *\"\\(.*\\)\".*/\\1/p" "${files[@]}" | tail -1
}

# Destroying anything outside dev needs CONFIRM=<env>: make down / down-all, apply.yml's confirm input.
require_destroy_confirm() {
  if [[ "$ENV_NAME" != dev && "${CONFIRM:-}" != "$ENV_NAME" ]]; then
    echo "Refusing to destroy '$ENV_NAME' without CONFIRM=$ENV_NAME" >&2
    exit 1
  fi
}

PROJECT="$(tfvar project)"
REGION="$(tfvar region)"
CLUSTER_NAME="$PROJECT-$ENV_NAME"
BASTION_NAME="$CLUSTER_NAME-bastion"
LOCAL_PORT="${LOCAL_PORT:-8443}"
KUBECONFIG_FILE="$ROOT_DIR/.kube/$ENV_NAME.kubeconfig"

# The MySQL instance Terraform manages (database output), unless DB_ID is set. Empty if none.
db_instance_id() {
  if [[ -n "${DB_ID:-}" ]]; then echo "$DB_ID"; return 0; fi
  tf_output database db_instance_identifier
}

# One output of a stack ("" if the stack or the output does not exist; -raw would print a warning).
tf_output() { # <stack> <output>
  { "$ROOT_DIR/scripts/run-stack.sh" "$ENV_NAME" "$1" output -json 2>/dev/null || echo '{}'; } |
    jq -r --arg o "$2" '.[$o].value // empty | if type == "string" then . else tojson end' 2>/dev/null || true
}

cluster_endpoint_host() {
  aws eks describe-cluster --region "$REGION" --name "$CLUSTER_NAME" \
    --query 'cluster.endpoint' --output text | sed 's#^https://##'
}

# Name(s) of this env's state bucket, found by tags (see bootstrap/state). Empty = none yet.
state_bucket_lookup() {
  aws resourcegroupstaggingapi get-resources --region "$REGION" --resource-type-filters s3:bucket \
    --tag-filters "Key=Project,Values=$PROJECT" "Key=Env,Values=$ENV_NAME" "Key=Purpose,Values=tfstate" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' | sed -e 's/^arn:[^:]*:s3:::*//' -e '/^$/d'
}

# This env's state bucket: TF_STATE_BUCKET if set, else exactly one bucket found by tags.
state_bucket() {
  if [[ -n "${TF_STATE_BUCKET:-}" ]]; then echo "$TF_STATE_BUCKET"; return; fi
  local found count
  found="$(state_bucket_lookup)" || {
    echo "Could not look up the state bucket of '$ENV_NAME' (see the AWS error above; check your credentials)" >&2
    return 1
  }
  count="$(printf '%s' "$found" | grep -c . || true)"
  if [[ "$count" -eq 0 ]]; then
    echo "No state bucket for '$ENV_NAME' in $REGION (tags Project=$PROJECT Env=$ENV_NAME Purpose=tfstate). Create it: make state ENV=$ENV_NAME" >&2
    return 1
  elif [[ "$count" -gt 1 ]]; then
    echo "Several state buckets for '$ENV_NAME'; set TF_STATE_BUCKET to one of:" >&2
    echo "$found" | sed 's/^/  /' >&2
    return 1
  fi
  echo "$found"
}

# True if a stack's state in the env's bucket has outputs. False if it was never applied or was destroyed
# (a destroy leaves the state file, with no outputs). Any other S3 error (credentials, permissions) stops the script.
stack_applied() { # <bucket> <stack>
  local state err
  err="$(mktemp)"
  if ! state="$(aws s3 cp --region "$REGION" "s3://$1/$2.tfstate" - 2>"$err")"; then
    if grep -q '(404)' "$err"; then rm -f "$err"; return 1; fi
    cat "$err" >&2
    rm -f "$err"
    exit 1
  fi
  rm -f "$err"
  jq -e '(.outputs // {}) | length > 0' <<<"$state" >/dev/null
}

# Plan or apply a run-once root (bootstrap/*) with a THROWAWAY local state in a temp dir.
# After a successful apply the outputs are printed and the state is deleted; after a failed
# apply it is kept, so the same apply can be re-run to finish instead of leaving half-made resources.
tf_throwaway() { # <root, e.g. bootstrap/state> plan|apply [terraform args...]
  local root="$1" action="$2" tmp
  shift 2
  tmp="$(mktemp -d)"
  local tf=(env TF_DATA_DIR="$tmp/.terraform" terraform -chdir="$ROOT_DIR/$root")
  "${tf[@]}" init -input=false -backend-config="path=$tmp/terraform.tfstate" >/dev/null
  if ! "${tf[@]}" "$action" "$@"; then
    if [[ "$action" == apply ]]; then
      echo "Apply failed. The temporary state is kept in $tmp; finish with:" >&2
      echo "  TF_DATA_DIR=$tmp/.terraform terraform -chdir=$root apply $*" >&2
    else
      rm -rf "$tmp"
    fi
    return 1
  fi
  [[ "$action" == apply ]] && "${tf[@]}" output
  rm -rf "$tmp"
}
