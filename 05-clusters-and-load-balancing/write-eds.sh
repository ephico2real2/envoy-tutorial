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
# The same client as run.sh: oc where it exists, kubectl otherwise (kind).
KUBE=$(command -v oc >/dev/null 2>&1 && echo oc || echo kubectl)

# Ready and not being deleted - the pods a control plane would publish. A pod
# with an IP is not enough: a terminating or unready pod still has one.
IPS=$($KUBE get pods -n "$NS" -l app=echo \
        -o jsonpath='{range .items[*]}{.status.podIP}{" "}{.status.containerStatuses[0].ready}{" "}{.metadata.deletionTimestamp}{"\n"}{end}' \
      | awk '$2 == "true" && NF == 2 { print $1 }' | sort)
if [ "$LIMIT" -gt 0 ]; then IPS=$(printf '%s\n' "$IPS" | head -n "$LIMIT"); fi
if [ -z "$IPS" ]; then
  echo "no Ready echo pods in $NS - nothing written" >&2
  exit 1
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
{
  echo 'resources:'
  echo '- "@type": type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment'
  echo '  cluster_name: eds'
  echo '  endpoints:'
  echo '  - lb_endpoints:'
  for ip in $IPS; do
    echo "    - endpoint: { address: { socket_address: { address: $ip, port_value: 8080 } } }"
  done
} > "$TMP"

$KUBE create configmap eds -n "$NS" --from-file=eds.yaml="$TMP" \
   --dry-run=client -o yaml | $KUBE apply -f - >/dev/null
echo "wrote $(printf '%s\n' "$IPS" | grep -c .) endpoint(s) to configmap/eds:"
printf '  %s:8080\n' $IPS
