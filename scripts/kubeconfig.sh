#!/usr/bin/env bash
# Write .kube/<env>.kubeconfig pointing at the SSM tunnel (https://localhost:$LOCAL_PORT)
# while still verifying the real EKS certificate (tls-server-name = endpoint host).
# kubectl authenticates as one of the env's roles (access), assumed from your own AWS identity:
#   ROLE=admin  (default) <project>-<env>-admin, cluster-admin
#   ROLE=viewer           <project>-<env>-viewer, read-only
#   ROLE=                 your current identity as is (e.g. a profile that already IS the viewer role)
# Usage: scripts/kubeconfig.sh [env]   then: export KUBECONFIG=.kube/<env>.kubeconfig
. "$(dirname "$0")/lib.sh" "${1:-}"
ROLE="${ROLE-admin}"

mkdir -p "$(dirname "$KUBECONFIG_FILE")"
HOST="$(cluster_endpoint_host)"
CLUSTER_ARN="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER_NAME" --query 'cluster.arn' --output text)"

ROLE_ARGS=()
if [[ -n "$ROLE" ]]; then
  ACCOUNT="$(cut -d: -f5 <<<"$CLUSTER_ARN")"
  ROLE_ARGS=(--role-arn "arn:aws:iam::$ACCOUNT:role/$CLUSTER_NAME-$ROLE")
fi

aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" \
  --kubeconfig "$KUBECONFIG_FILE" --alias "$CLUSTER_NAME" ${ROLE_ARGS[@]+"${ROLE_ARGS[@]}"} >/dev/null

KUBECONFIG="$KUBECONFIG_FILE" kubectl config set-cluster "$CLUSTER_ARN" \
  --server "https://localhost:$LOCAL_PORT" --tls-server-name "$HOST" >/dev/null
chmod 600 "$KUBECONFIG_FILE"

echo "Wrote $KUBECONFIG_FILE (as ${ROLE:-your current identity})"
echo "  export KUBECONFIG=$KUBECONFIG_FILE"
