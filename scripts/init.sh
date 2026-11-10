#!/usr/bin/env bash
# `make init`: check what whoever runs this infra code needs: the local tools, and AWS credentials
# that can create it. Read-only. Run it on your machine (or a CI runner) before anything else.
set -euo pipefail

TERRAFORM_MIN="1.11" # S3 native state locking (1.10), write-only arguments (1.11)

missing=0
check() { # <command> <version command...>
  local cmd="$1"; shift
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "  %-24s %s\n" "$cmd" "$("$@" 2>&1 | head -1)"
  else
    printf "  %-24s MISSING\n" "$cmd"
    missing=1
  fi
}

echo "==> Required tools"
check terraform              terraform version
check aws                    aws --version
check session-manager-plugin session-manager-plugin --version
check kubectl                kubectl version --client
check uv                     uv --version # Python commands (scripts/py/main.py): uv run --script

if command -v terraform >/dev/null 2>&1; then
  tf_version="$(terraform version -json | sed -n 's/.*"terraform_version": *"\([^"]*\)".*/\1/p')"
  if [[ "$(printf '%s\n%s\n' "$TERRAFORM_MIN" "$tf_version" | sort -V | head -1)" != "$TERRAFORM_MIN" ]]; then
    echo "  terraform $tf_version is too old, need >= $TERRAFORM_MIN"
    missing=1
  fi
fi

echo "==> Optional"
if command -v gh >/dev/null 2>&1; then
  printf "  %-24s %s\n" gh "$(gh --version | head -1)"
else
  printf "  %-24s not installed (only needed to manage GitHub repo variables/environments from the CLI)\n" gh
fi

if [[ "$missing" -ne 0 ]]; then
  echo "Install the missing tools above and run 'make init' again." >&2
  exit 1
fi

# ---------------------------------------------------------------------------------------------
echo "==> AWS identity (the credentials of this shell: AWS_PROFILE, env vars or SSO)"
if ! IDENTITY="$(aws sts get-caller-identity --query Arn --output text 2>&1)"; then
  echo "  No usable AWS credentials: $IDENTITY" >&2
  echo "  Configure them (aws configure / aws sso login / AWS_PROFILE=...) and run 'make init' again." >&2
  exit 1
fi
ACCOUNT="$(cut -d: -f5 <<<"$IDENTITY")"
REGION="$(. "$(dirname "$0")/lib.sh" --account && echo "$REGION")"
printf "  %-24s %s\n" account "$ACCOUNT" identity "$IDENTITY" "region (envs/base)" "$REGION"

# Best effort: IAM policy simulation of one representative action per part of the stack.
# It sees the identity's policies and permission boundary, not every SCP or resource policy,
# so "allowed" means "very likely", and a denied action is worth a look before `make up`.
echo "==> AWS permissions (IAM policy simulation, best effort)"
case "$IDENTITY" in
  *:assumed-role/*) # arn:aws:sts::<acct>:assumed-role/<role>/<session> -> the role itself
    ROLE_NAME="$(cut -d/ -f2 <<<"$IDENTITY")"
    SOURCE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text 2>/dev/null ||
      echo "arn:aws:iam::$ACCOUNT:role/$ROLE_NAME")" ;;
  *) SOURCE_ARN="$IDENTITY" ;;
esac

ACTIONS=(
  "s3:CreateBucket                         state bucket, app buckets"
  "tag:GetResources                        finding the state bucket by tags"
  "iam:CreateOpenIDConnectProvider         bootstrap/oidc (once per account)"
  "iam:CreateRole                          access, EKS and node roles"
  "iam:PassRole                            EKS, RDS monitoring, AWS Backup"
  "ec2:CreateVpc                           network"
  "eks:CreateCluster                       eks"
  "rds:CreateDBInstance                    database"
  "backup:CreateBackupVault                database (AWS Backup)"
  "sqs:CreateQueue                         app-aws"
  "elasticloadbalancing:CreateLoadBalancer lb"
  "ssm:StartSession                        make tunnel"
  "codebuild:CreateProject                 ci-runner (only with CI)"
)
NAMES=()
for a in "${ACTIONS[@]}"; do NAMES+=("${a%% *}"); done

if ! RESULTS="$(aws iam simulate-principal-policy --policy-source-arn "$SOURCE_ARN" --action-names "${NAMES[@]}" \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text 2>&1)"; then
  echo "  Could not run the simulation (needs iam:SimulatePrincipalPolicy): ${RESULTS##*: }"
  echo "  Not an error: permissions will show up on the first plan/apply instead."
  perms="not checked"
else
  denied=0
  for a in "${ACTIONS[@]}"; do
    name="${a%% *}"
    decision="$(awk -v n="$name" '$1 == n { print $2 }' <<<"$RESULTS")"
    [[ "$decision" == allowed ]] && mark=ok || { mark="DENIED ($decision)"; denied=1; }
    printf "  %-40s %-18s %s\n" "$name" "$mark" "$(sed 's/^[^ ]* *//' <<<"$a")"
  done
  if [[ "$denied" -eq 0 ]]; then
    perms="look sufficient"
  else
    perms="partly DENIED, see above"
    echo "  Some actions look denied: ask for them before the matching 'make up' (or use another identity)."
  fi
fi

# ---------------------------------------------------------------------------------------------
# Only for GitHub Actions (github_repo set for access). Without CI there is nothing to check.
echo "==> GitHub Actions (optional: only needed for ci.yml / apply.yml)"
IFS='|' read -r REPO CONNECTION < <(. "$(dirname "$0")/lib.sh" --account &&
  echo "$(tfvar github_repo access)|$(tfvar github_connection_name ci-runner)")
CONNECTION="${CONNECTION:-github}" # ci-runner default
if [[ -z "$REPO" ]]; then
  echo "  github_repo not set (envs/base/access.tfvars): no CI roles, no runner, nothing to check"
  ci="not used"
else
  STATUS="$(aws codestar-connections list-connections --region "$REGION" --provider-type-filter GitHub \
    --query "Connections[?ConnectionName=='$CONNECTION'].ConnectionStatus | [0]" --output text 2>&1)" || STATUS="not checked (${STATUS##*: })"
  case "$STATUS" in
    AVAILABLE) ci="ready" ;;
    PENDING) ci="connection PENDING"; echo "  Finish the GitHub handshake in the console (docs/DEPLOYMENT.md)." ;;
    None) STATUS="missing"; ci="connection missing"; echo "  Create it once per account and region (docs/DEPLOYMENT.md); the ci-runner stack needs it." ;;
    *) ci="connection $STATUS" ;;
  esac
  printf "  %-24s %s\n" repository "$REPO" "connection ($REGION)" "$CONNECTION: $STATUS"
fi

echo "Tools present; AWS credentials work for account $ACCOUNT; permissions $perms; GitHub Actions $ci."
