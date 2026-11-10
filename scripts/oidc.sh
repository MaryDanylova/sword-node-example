#!/usr/bin/env bash
# Create the account's GitHub Actions OIDC provider (bootstrap/oidc), exactly once.
#
# Account-wide, not per env or repo: one provider per issuer URL serves every repository.
# Throwaway state (see tf_throwaway in lib.sh). A second run - or an account that already has a
# provider, e.g. made by another project - stops on purpose and prints the existing ARN.
#
# Usage: scripts/oidc.sh plan     preview (read-only)
#        scripts/oidc.sh create   create the provider (asks for confirmation)
#        OIDC_URL=https://<host>/_services/token scripts/oidc.sh ...   GitHub Enterprise Server
. "$(dirname "$0")/lib.sh" --account
ACTION="${1:-plan}"
[[ "$ACTION" == plan || "$ACTION" == create ]] || { echo "Usage: $0 plan|create" >&2; exit 1; }
URL="${OIDC_URL:-https://token.actions.githubusercontent.com}"

echo "==> AWS identity"
aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table

EXISTING="$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text |
  tr '\t' '\n' | grep -F "oidc-provider/${URL#https://}" || true)"
if [[ -n "$EXISTING" ]]; then
  echo "The account already has an OIDC provider for $URL, nothing to do:" >&2
  echo "  $EXISTING" >&2
  exit 1
fi

tf_throwaway bootstrap/oidc "${ACTION/create/apply}" -var="region=$REGION" -var="url=$URL"
