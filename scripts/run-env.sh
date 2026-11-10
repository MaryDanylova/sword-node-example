#!/usr/bin/env bash
# Bring a whole environment up or down, or plan it, stack by stack in dependency order.
#
# Usage: scripts/run-env.sh up|down|plan <env> [extra terraform args]
#        Normally through make: make up-all | down-all | plan-all ENV=<env>
#        Outside dev, down also needs CONFIRM=<env>.
#
# Order
#   up, plan  the STACKS order in scripts/lib.sh
#   down      the reverse: the DB and ALB security groups and the Pod Identity associations
#             reference the EKS node security group and cluster, so they must go before eks
#
# Plan skips a stack, with a note, when
#   - an upstream stack is not applied (no state, or the empty state a destroy leaves)
#   - it needs the Kubernetes API and the cluster does not exist
#   Any error from Terraform stops the run.
#
# Environment variables
#   K8S_VIA=tunnel     how to reach the private API for app-k8s (default): reuses a tunnel listening
#                      on localhost:$LOCAL_PORT, or starts one for that step and stops it at the end
#   K8S_VIA=codebuild  runs app-k8s as a build inside the VPC (stacks/ci-runner) on the pushed commit;
#                      apply.yml uses it, so CI needs no tunnel
#   NO_K8S=1           skips the stacks that need the Kubernetes API (CI plans cannot reach it)
#   ONLY=<stack>       runs just that stack, keeping the tunnel handling (ONLY=app-k8s make up-all)
#
# Good to know
#   - Safe to re-run after a failure: finished stacks are no-ops for Terraform.
#   - HUMAN_ONLY stacks (access) run only when named in ONLY, and never with down: they hold the role
#     apply.yml runs with. Destroy them with make down STACK=access.
#   - bootstrap/* is never touched.
. "$(dirname "$0")/lib.sh" "${2:-}"

ACTION="${1:-}"
shift $(($# < 2 ? $# : 2))
ARGS="$*"
[[ "$ACTION" == up || "$ACTION" == down || "$ACTION" == plan ]] || { echo "usage: $0 up|down|plan <env> [terraform args]" >&2; exit 1; }

if [[ "$ACTION" == down ]]; then require_destroy_confirm; fi # before any stack is touched
K8S_VIA="${K8S_VIA:-tunnel}"
[[ "$K8S_VIA" == tunnel || "$K8S_VIA" == codebuild ]] || { echo "K8S_VIA must be tunnel or codebuild" >&2; exit 1; }

cd "$ROOT_DIR"
# Look the state bucket up once; every scripts/run-stack.sh run below reuses it.
TF_STATE_BUCKET="$(state_bucket)"
export TF_STATE_BUCKET
if [[ -n "${ONLY:-}" ]]; then
  in_list "$ONLY" "${STACKS[@]}" || { echo "Unknown stack '$ONLY' (have: ${STACKS[*]})" >&2; exit 1; }
  if in_list "$ONLY" "${HUMAN_ONLY[@]}" && [[ "$ACTION" == down ]]; then
    echo "Refusing to destroy $ONLY here: it holds the role CI applies with. Use make down STACK=$ONLY ENV=$ENV_NAME." >&2
    exit 1
  fi
  RUN=("$ONLY")
else
  RUN=()
  for s in "${STACKS[@]}"; do in_list "$s" "${HUMAN_ONLY[@]}" || RUN+=("$s"); done
fi
if [[ "$ACTION" == down ]]; then # reverse (macOS bash 3.2: no mapfile)
  REV=()
  for ((i = ${#RUN[@]} - 1; i >= 0; i--)); do REV+=("${RUN[i]}"); done
  RUN=("${REV[@]}")
fi

banner() { printf '\n\033[1;36m==> [%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }

# ------------------------------------------------------------------------------
# Tunnel (only for stacks that need the Kubernetes API): scripts/tunnel-up.sh reuses one that is
# listening or starts one; only a tunnel started here is stopped here.
# ------------------------------------------------------------------------------
TUNNEL_PID=""

stop_tunnel() {
  [[ -n "$TUNNEL_PID" ]] || return 0
  pkill -P "$TUNNEL_PID" 2>/dev/null || true # session-manager-plugin child
  kill "$TUNNEL_PID" 2>/dev/null || true
  TUNNEL_PID=""
}
trap stop_tunnel EXIT

ensure_tunnel() {
  local pid
  pid="$("$ROOT_DIR/scripts/tunnel-up.sh" "$ENV_NAME")" || exit 1
  [[ -z "$pid" ]] || TUNNEL_PID="$pid"
}

cluster_exists() { aws eks describe-cluster --region "$REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1; }

# One stack: make here, or a CodeBuild build in the VPC for the k8s stacks with K8S_VIA=codebuild.
VIA_CODEBUILD=""
run_stack() { # plan|up|down
  if [[ -n "$VIA_CODEBUILD" ]]; then
    # shellcheck disable=SC2086 # ARGS is a list of terraform args
    "$ROOT_DIR/scripts/py/main.py" codebuild "$ENV_NAME" "$stack" "$1" $ARGS
  else
    make --no-print-directory "$1" STACK="$stack" ENV="$ENV_NAME" ARGS="$ARGS"
  fi
}

# ------------------------------------------------------------------------------
# Run
# ------------------------------------------------------------------------------
START=$(date +%s)
SUMMARY=() # plan: one line per stack, printed at the end
banner "$ACTION-all ENV=$ENV_NAME: ${RUN[*]}"

# The first upstream of a stack that is not applied; nothing if all of them are.
unapplied_upstream() { # <stack>
  local dep
  for dep in $(stack_upstreams "$1"); do
    stack_applied "$TF_STATE_BUCKET" "$dep" || { echo "$dep"; return 0; }
  done
}

for stack in "${RUN[@]}"; do
  VIA_CODEBUILD=""
  if [[ "$ACTION" == plan ]]; then
    missing="$(unapplied_upstream "$stack")"
    if [[ -n "$missing" ]]; then
      banner "$stack: skipped - upstream stack $missing is not applied in '$ENV_NAME'"
      SUMMARY+=("$stack: skipped ($missing not applied)")
      continue
    fi
  fi
  if grep -q 'provider "kubernetes"' "stacks/$stack"/*.tf 2>/dev/null; then
    if [[ -n "${NO_K8S:-}" ]]; then
      banner "$stack: skipped - NO_K8S is set"
      SUMMARY+=("$stack: skipped (NO_K8S)")
      continue
    fi
    if [[ "$ACTION" != up ]] && ! cluster_exists; then
      banner "$stack: skipped - cluster $CLUSTER_NAME does not exist"
      SUMMARY+=("$stack: skipped (no cluster)")
      continue
    fi
    if [[ "$K8S_VIA" == codebuild ]]; then VIA_CODEBUILD=1; else ensure_tunnel; fi
  fi

  banner "$stack: $ACTION"
  if [[ "$ACTION" == plan ]]; then
    PLAN_LOG="$(mktemp)"
    rc=0
    run_stack plan 2>&1 | tee "$PLAN_LOG" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "plan failed for $stack, see above" >&2
      rm -f "$PLAN_LOG"
      exit 1
    fi
    # Colors off first: locally the plan is colored. A plan with only output changes has no such line.
    SUMMARY+=("$stack: $(sed $'s/\x1b\\[[0-9;]*m//g' "$PLAN_LOG" | grep -E '^(Plan:|No changes)' | tail -1 || true)")
    rm -f "$PLAN_LOG"
    continue
  fi
  run_stack "$ACTION"

  # down: app-k8s is the last stack needing the API (up: lb after it needs none either).
  [[ "$ACTION" == down && "$stack" == app-k8s ]] && stop_tunnel
done

banner "$ACTION-all ENV=$ENV_NAME finished in $((($(date +%s) - START) / 60)) min"

if [[ "$ACTION" == plan ]]; then
  echo "Summary ($ENV_NAME):"
  printf '  %s\n' "${SUMMARY[@]}"
elif [[ "$ACTION" == down ]]; then
  # Final snapshots of every instance of the env (database's, or one retired by db-restore).
  DB_PREFIX="$CLUSTER_NAME-mysql-"
  FINAL="$(aws rds describe-db-snapshots --region "$REGION" --snapshot-type manual \
    --query "reverse(sort_by(DBSnapshots[?starts_with(DBSnapshotIdentifier, '$DB_PREFIX') && contains(DBSnapshotIdentifier, '-final-')], &SnapshotCreateTime))[0].DBSnapshotIdentifier" \
    --output text 2>/dev/null || true)"
  cat <<EOF

Left in place on purpose: state bucket (bootstrap/state), roles (access), RDS final snapshot(s), retained automated backups (PITR, expire by retention).
EOF
  if [[ -n "$FINAL" && "$FINAL" != "None" ]]; then
    cat <<EOF
The next 'make up-all' starts with an EMPTY database. To keep the data, create it from the final snapshot
(nothing to commit or undo: the value only matters when the instance is created):
  TF_VAR_restore_snapshot_id=$FINAL make up-all ENV=$ENV_NAME
Other restore points: make db-restore ENV=$ENV_NAME ARGS=list
EOF
  fi
else
  cat <<EOF

Access (terminal 1, keep it running):
  make tunnel ENV=$ENV_NAME
Access (terminal 2):
  make kubeconfig ENV=$ENV_NAME   # once per cluster; ROLE=viewer for read-only
  export KUBECONFIG=.kube/$ENV_NAME.kubeconfig
Checks:
  make verify ENV=$ENV_NAME
EOF
fi
