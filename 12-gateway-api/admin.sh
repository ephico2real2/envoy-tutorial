#!/usr/bin/env bash
# admin.sh <path> - ask the Envoy that Envoy Gateway generated for the Gateway
# "eg" one admin-API question, e.g.  ./admin.sh 'config_dump?resource=dynamic_active_clusters'
#
# The generated Envoy listens for admin requests on 127.0.0.1:19000 inside its
# pod only, and its image is distroless - no shell, no curl to exec. So forward
# a local port to it for the one request, and stop the forward afterwards.
set -euo pipefail
[ $# -eq 1 ] || { sed -n '2,3p' "$0" | sed 's/^# //'; exit 2; }
KUBE=$(command -v oc >/dev/null 2>&1 && echo oc || echo kubectl)
PORT=${ADMIN_LOCAL_PORT:-19000}

DEPLOY=$($KUBE get deploy -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=eg,gateway.envoyproxy.io/owning-gateway-namespace=gwapi-demo -o name)
[ -n "$DEPLOY" ] || { echo "no Envoy Deployment for gateway gwapi-demo/eg - is it deployed?" >&2; exit 1; }

$KUBE port-forward -n envoy-gateway-system "$DEPLOY" "$PORT:19000" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
# The forward takes a moment to open; wait for it rather than for a fixed time.
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/ready" && break
  sleep 0.2
done
curl -sS --fail "http://127.0.0.1:$PORT/${1#/}"
