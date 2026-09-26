#!/usr/bin/env bash
# eg-admin.sh <namespace>/<gateway> <path> - ask the Envoy that Envoy Gateway
# generated for that Gateway one admin-API question, e.g.
#   ../_shared/eg-admin.sh envoy-13/eg 'config_dump?resource=dynamic_route_configs'
#
# The generated Envoy listens for admin requests on 127.0.0.1:19000 inside its
# pod only, and its image is distroless - no shell, no curl to exec. So forward
# a free local port to it for the one request, and stop the forward afterwards.
set -euo pipefail
[ $# -eq 2 ] && [[ $1 == */* ]] || { sed -n '2,4p' "$0" | sed 's/^# //'; exit 2; }
KUBE=$(command -v oc >/dev/null 2>&1 && echo oc || echo kubectl)
NS=${1%%/*} GW=${1#*/}

DEPLOY=$($KUBE get deploy -n envoy-gateway-system \
  -l "gateway.envoyproxy.io/owning-gateway-name=$GW,gateway.envoyproxy.io/owning-gateway-namespace=$NS" -o name)
[ -n "$DEPLOY" ] || { echo "no Envoy Deployment for gateway $NS/$GW - is it deployed?" >&2; exit 1; }

# A free port, chosen by the OS, so two forwards never collide.
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
$KUBE port-forward -n envoy-gateway-system "$DEPLOY" "$PORT:19000" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
# The forward takes a moment to open; wait for it rather than for a fixed time.
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/ready" && break
  kill -0 $PF 2>/dev/null || { echo "port-forward to $DEPLOY exited" >&2; exit 1; }
  sleep 0.2
done
curl -sS --fail "http://127.0.0.1:$PORT/${2#/}"
