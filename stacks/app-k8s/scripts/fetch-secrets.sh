set -eu
get() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text | jq -r '.username, .password'; }
get "$MASTER_SECRET_ARN" > /creds/master
get "$APP_SECRET_ARN" > /creds/app
get "$MONITOR_SECRET_ARN" > /creds/monitor
