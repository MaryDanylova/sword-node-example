#!/usr/bin/env bash
# Make sure the env's Kubernetes API answers on localhost:$LOCAL_PORT, for a script that needs it for
# a while (run-env.sh for app-k8s, db-restore for check and cutover).
#
# Usage: pid="$(scripts/tunnel-up.sh <env>)"
#
#   1. A tunnel already listening on the port is reused and left alone. Otherwise scripts/tunnel.sh
#      starts in the background, logging to .kube/<env>.tunnel.log. It retries, because a new bastion
#      takes a minute or two to register with SSM.
#   2. The kubeconfig is written and the API must answer.
#
# stdout   the PID of the tunnel this started, or nothing if it reused one. Only that PID is the
#          caller's to stop, when it is done: pkill -P <pid>; kill <pid>
# stderr   messages
# Exit 1   the API is not reachable (a tunnel started here is stopped first)
. "$(dirname "$0")/lib.sh" "${1:-}"

TUNNEL_PID=""
TUNNEL_LOG="$ROOT_DIR/.kube/$ENV_NAME.tunnel.log"

stop_tunnel() {
  [[ -n "$TUNNEL_PID" ]] || return 0
  pkill -P "$TUNNEL_PID" 2>/dev/null || true # session-manager-plugin child
  kill "$TUNNEL_PID" 2>/dev/null || true
  TUNNEL_PID=""
}
fail() {
  echo "$*" >&2
  stop_tunnel
  exit 1
}
listening() { nc -z localhost "$LOCAL_PORT" 2>/dev/null; }

if listening; then
  echo "Using the tunnel already listening on localhost:$LOCAL_PORT" >&2
else
  mkdir -p "$(dirname "$TUNNEL_LOG")"
  for attempt in $(seq 1 20); do
    # Detached from our stdout/stderr, so the caller's $(...) returns while the tunnel keeps running.
    "$ROOT_DIR/scripts/tunnel.sh" "$ENV_NAME" </dev/null >"$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!
    for _ in $(seq 1 15); do
      listening && break 2
      kill -0 "$TUNNEL_PID" 2>/dev/null || break
      sleep 1
    done
    stop_tunnel
    echo "  tunnel not ready (attempt $attempt/20), retrying in 15s... ($(tail -1 "$TUNNEL_LOG" 2>/dev/null))" >&2
    sleep 15
  done
  listening || fail "Could not open the tunnel, see $TUNNEL_LOG"
  echo "Started a background tunnel (pid $TUNNEL_PID, log $TUNNEL_LOG)" >&2
fi

"$ROOT_DIR/scripts/kubeconfig.sh" "$ENV_NAME" >/dev/null || fail "kubeconfig.sh failed"
for _ in $(seq 1 12); do
  if KUBECONFIG="$KUBECONFIG_FILE" kubectl get --raw /version >/dev/null 2>&1; then
    echo "$TUNNEL_PID"
    exit 0
  fi
  sleep 5
done
fail "The tunnel is open but the API does not answer"
