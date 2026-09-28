#!/usr/bin/env bash
# admin.sh <path> - ask the front Envoy in envoy-20 one admin-API question, e.g.
#   ./admin.sh server_info
#   ./admin.sh 'config_dump?resource=static_listeners'
#
# The admin API answers on the pod's loopback only (manifests/70-front-envoy-config.yaml),
# and the Envoy image has no curl to exec. So forward a free local port to it for the one
# request - oc port-forward reaches the pod's own loopback - and stop the forward after.
# The same way ../_shared/eg-admin.sh asks the Envoys that Envoy Gateway runs.
set -euo pipefail
[ $# -eq 1 ] || { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
KUBE=$(command -v oc >/dev/null 2>&1 && echo oc || echo kubectl)

# A free port, chosen by the OS, so two forwards never collide.
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
$KUBE port-forward -n envoy-20 deploy/front-envoy "$PORT:9901" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
# The forward takes a moment to open; wait for it rather than for a fixed time.
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/ready" && break
  kill -0 $PF 2>/dev/null || { echo "admin.sh: the port-forward to deploy/front-envoy exited" >&2; exit 1; }
  sleep 0.2
done
curl -sS --fail "http://127.0.0.1:$PORT/${1#/}"
