#!/usr/bin/env bash
# Runs SQL as the master user against the private RDS instance from a short-lived mysql pod (the DB
# only accepts connections from the EKS nodes). Credentials come from the RDS-managed master secret
# and are passed over stdin - never on a command line or in a pod spec.
#
# Usage: scripts/db-sql.sh <env> "<SQL>"
#        DB_ID=<instance> scripts/db-sql.sh <env> "<SQL>"
#          Default: the instance the database stack manages. DB_ID reaches another one, for example
#          a restored one before the cutover (make db-restore ARGS='restore <point> --stop-before-cutover').
# Needs `make tunnel ENV=<env>` running.
. "$(dirname "$0")/lib.sh" "${1:-}"
SQL="${2:?usage: $0 <env> \"<SQL>\"}"

export KUBECONFIG="$KUBECONFIG_FILE"
DB_ID="$(db_instance_id)"
[[ -n "$DB_ID" ]] || { echo "No MySQL instance in database for '$ENV_NAME' (or set DB_ID)" >&2; exit 1; }
POD="db-sql-$(date +%s)"

read -r DB_HOST SECRET_ARN < <(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].[Endpoint.Address,MasterUserSecret.SecretArn]' --output text)
SECRET="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_ARN" --query SecretString --output text)"

trap 'kubectl delete pod -n default "$POD" --ignore-not-found --wait=false >/dev/null 2>&1' EXIT
kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: $POD, namespace: default }
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  securityContext: { runAsNonRoot: true, runAsUser: 999, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: mysql
      image: mysql:8.4
      command: ["sleep", "600"]
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
YAML
kubectl wait --for=condition=Ready -n default "pod/$POD" --timeout=180s >/dev/null

jq -r .password <<<"$SECRET" | kubectl exec -i -n default "$POD" -- \
  sh -c 'read -r P; MYSQL_PWD="$P" mysql -h "$0" -u "$1" --ssl-mode=REQUIRED --table -e "$2"' \
  "$DB_HOST" "$(jq -r .username <<<"$SECRET")" "$SQL"
