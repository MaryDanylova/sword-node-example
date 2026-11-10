#!/usr/bin/env bash
# Delete an environment's Terraform state bucket: the last step of removing an env for good.
#
# Usage: scripts/clean.sh <env>      (make clean ENV=<env>)
#
#   1. Lists what would remain: the env's data kept on purpose, and account-wide resources shared
#      with other envs. These are warnings only, this script never deletes them.
#   2. Refuses if any state still holds resources: without its state, Terraform can no longer
#      destroy them. Run `make down-all`, then `make down STACK=access`.
#   3. Asks you to type the bucket name at a terminal. There is no flag to skip this, and piped input is refused.
. "$(dirname "$0")/lib.sh" "${1:-}"

BUCKET="$(state_bucket)"
NAME_PREFIX="$CLUSTER_NAME-"

# Print a list under a heading if it has entries; a failed lookup is reported, not ignored.
report() { # <title> <command...>
  local title="$1" out
  shift
  if ! out="$("$@" 2>&1)"; then
    printf '  %-32s could not check: %s\n' "$title" "${out##*: }"
  elif [[ -n "$out" && "$out" != None ]]; then
    printf '  %s:\n' "$title"
    printf '%s\n' "$out" | tr '\t' ' ' | sed 's/^/    /'
  fi
}

echo "==> Env '$ENV_NAME': data kept on purpose, not deleted here (costs little, expires or stays until you delete it)"
report "RDS manual and final snapshots" aws rds describe-db-snapshots --region "$REGION" --snapshot-type manual --output text \
  --query "DBSnapshots[?starts_with(DBSnapshotIdentifier, '$NAME_PREFIX')].[DBSnapshotIdentifier]"
report "RDS retained automated backups" aws rds describe-db-instance-automated-backups --region "$REGION" --output text \
  --query "DBInstanceAutomatedBackups[?starts_with(DBInstanceIdentifier, '$NAME_PREFIX')].[DBInstanceIdentifier, Status]"
report "AWS Backup vaults" aws backup list-backup-vaults --region "$REGION" --output text \
  --query "BackupVaultList[?starts_with(BackupVaultName, '$CLUSTER_NAME')].[BackupVaultName, NumberOfRecoveryPoints]"
report "Secrets (incl. pending deletion)" aws secretsmanager list-secrets --region "$REGION" --include-planned-deletion --output text \
  --query "SecretList[?starts_with(Name, '$NAME_PREFIX')].[Name]"
report "CloudWatch log groups" aws logs describe-log-groups --region "$REGION" --output text \
  --query "logGroups[?contains(logGroupName, '/$CLUSTER_NAME/') || contains(logGroupName, '/$NAME_PREFIX')].[logGroupName]"

echo
echo "==> Account-wide, shared with other envs and repositories: WARNING, delete only if nothing else uses them"
report "GitHub OIDC provider (make oidc)" aws iam list-open-id-connect-providers --output text \
  --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].[Arn]"
report "CodeConnections connections" aws codestar-connections list-connections --region "$REGION" --provider-type-filter GitHub --output text \
  --query "Connections[].[ConnectionName, ConnectionStatus]"

echo
echo "==> State bucket $BUCKET"
LEFT=0
KEYS="$(aws s3api list-objects-v2 --bucket "$BUCKET" --output text --query "Contents[?ends_with(Key, '.tfstate')].Key")"
for key in $KEYS; do
  [[ "$key" == None ]] && continue
  count="$(aws s3 cp --region "$REGION" "s3://$BUCKET/$key" - | jq '[.resources[]? | select(.mode == "managed")] | length')"
  printf '  %-24s %s resources\n' "$key" "$count"
  [[ "$count" -eq 0 ]] || LEFT=1
done
if [[ "$LEFT" -ne 0 ]]; then
  echo "Refusing to delete the bucket: Terraform could no longer destroy these resources. First:" >&2
  echo "  make down-all ENV=$ENV_NAME" >&2
  echo "  make down STACK=access ENV=$ENV_NAME" >&2
  exit 1
fi

echo
echo "This permanently deletes the bucket, with every version of every state file."
[[ -t 0 ]] || { echo "Not a terminal: run this yourself, it has to be confirmed by hand." >&2; exit 1; }
read -r -p "Type the bucket name to continue: " ANSWER
[[ "$ANSWER" == "$BUCKET" ]] || { echo "Not confirmed, nothing deleted." >&2; exit 1; }

# Versioned bucket: every version and delete marker has to go. delete-objects takes at most 1000 keys.
while :; do
  BATCH="$(aws s3api list-object-versions --bucket "$BUCKET" --max-items 1000 --output json |
    jq -c '{Quiet: true, Objects: ([(.Versions // [])[], (.DeleteMarkers // [])[] | {Key, VersionId}] | .[0:1000])}')"
  [[ "$(jq '.Objects | length' <<<"$BATCH")" -gt 0 ]] || break
  aws s3api delete-objects --bucket "$BUCKET" --delete "$BATCH" >/dev/null
done
aws s3api delete-bucket --bucket "$BUCKET"

echo "Deleted $BUCKET."
echo "If '$ENV_NAME' is gone for good, also remove envs/overlays/$ENV_NAME/: ci.yml plans every env declared there."
