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

DEPLOY=$($KUBE get deploy -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=eg,gateway.envoyproxy.io/owning-gateway-namespace=gwapi-demo -o name)
[ -n "$DEPLOY" ] || { echo "no Envoy Deployment for gateway gwapi-demo/eg - is it deployed?" >&2; exit 1; }

# Local port 0: the forward binds a port the OS says is free, and prints it. A
# fixed port can already be held - by another forward, or by this script's own
# previous run still closing - and whatever holds it would answer instead.
PF_OUT=$(mktemp)
$KUBE port-forward -n envoy-gateway-system "$DEPLOY" :19000 >"$PF_OUT" 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null; rm -f "$PF_OUT"' EXIT
PORT=
for _ in $(seq 1 50); do
  PORT=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) .*/\1/p' "$PF_OUT")
  [ -n "$PORT" ] && break
  kill -0 "$PF" 2>/dev/null || break
  sleep 0.2
done
[ -n "$PORT" ] || { echo "port-forward to $DEPLOY did not start:" >&2; cat "$PF_OUT" >&2; exit 1; }
curl -sS --fail "http://127.0.0.1:$PORT/${1#/}"
