#!/usr/bin/env bash
# Forward the private EKS API endpoint to https://localhost:$LOCAL_PORT through the SSM bastion.
# Keep it running in its own terminal. Usage: scripts/tunnel.sh [env]
. "$(dirname "$0")/lib.sh" "${1:-}"

command -v session-manager-plugin >/dev/null || { echo "Install session-manager-plugin first" >&2; exit 1; }

BASTION_ID="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=$BASTION_NAME" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"
[[ "$BASTION_ID" != "None" && -n "$BASTION_ID" ]] || { echo "No running bastion '$BASTION_NAME' (enable_bastion = true?)" >&2; exit 1; }

HOST="$(cluster_endpoint_host)"
echo "Tunnel: localhost:$LOCAL_PORT -> $BASTION_ID -> $HOST:443   (Ctrl+C to stop)"

exec aws ssm start-session --region "$REGION" --target "$BASTION_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=$HOST,portNumber=443,localPortNumber=$LOCAL_PORT"
