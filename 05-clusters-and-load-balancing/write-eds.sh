#!/usr/bin/env bash
# The smallest possible "control plane": list the echo pods' IPs and write them
# into the `eds` ConfigMap as a ClusterLoadAssignment - the same resource a real
# control plane (Envoy Gateway, Istio) sends over the network.
#
#   ./write-eds.sh            write every Ready echo pod
#   ./write-eds.sh 1          write only the first one
#
# Envoy is not restarted. It watches /etc/eds and reloads the file when the
# ConfigMap update lands there.
set -euo pipefail
NS=envoy-05
LIMIT=${1:-0}

IPS=$(oc get pods -n "$NS" -l app=echo \
        -o jsonpath='{range .items[?(@.status.podIP)]}{.status.podIP}{"\n"}{end}' | sort)
[ "$LIMIT" -gt 0 ] && IPS=$(printf '%s\n' "$IPS" | head -n "$LIMIT")

{
  echo 'resources:'
  echo '- "@type": type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment'
  echo '  cluster_name: eds'
  echo '  endpoints:'
  echo '  - lb_endpoints:'
  for ip in $IPS; do
    echo "    - endpoint: { address: { socket_address: { address: $ip, port_value: 8080 } } }"
  done
} > "${TMPDIR:-/tmp}/eds.yaml"

oc create configmap eds -n "$NS" --from-file=eds.yaml="${TMPDIR:-/tmp}/eds.yaml" \
   --dry-run=client -o yaml | oc apply -f - >/dev/null
echo "wrote $(printf '%s\n' "$IPS" | grep -c .) endpoint(s) to configmap/eds:"
printf '  %s:8080\n' $IPS
