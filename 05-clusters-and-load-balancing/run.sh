#!/usr/bin/env bash
# Module 05 — clusters and load balancing.  ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=envoy-05
. ../_shared/lib.sh

deploy() {
  say "deploying into $NS"
  ns_ensure
  $KUBE apply -n "$NS" -f ../_shared/echo-app.yaml >/dev/null
  # Three pods, so an uneven split is visible.
  $KUBE scale -n "$NS" deploy/echo --replicas=3 >/dev/null
  $KUBE apply -n "$NS" -f manifests/ >/dev/null
  wait_ready echo; wait_ready sick; wait_ready envoy; wait_ready envoy-single
  wait_upstream headless envoy
  wait_upstream headless envoy-single
  ok "echo (3), sick, envoy and envoy-single are up"
}

# members <cluster> [envoy-service] - the endpoint addresses Envoy holds for a cluster.
members() {
  incluster_curl "http://${2:-envoy}.$NS.svc:9901/clusters" \
    | awk -F'::' -v c="$1" '$1 == c && $3 == "health_flags" { print $2 }' | sort
}
# spread <path> <n> [envoy-service] - how many of n requests each pod served, sorted.
spread() {
  incluster_sh "for i in \$(seq 1 $2); do curl -s http://${3:-envoy}:8080$1 | grep -o 'echo-[a-z0-9]*-[a-z0-9]*'; done" \
    | sort | uniq -c | awk '{ print $1 }' | sort -n | tr '\n' ' ' | sed 's/ $//'
}
# codes <path> <n> - status codes for n requests, as "count×code".
codes() {
  incluster_sh "for i in \$(seq 1 $2); do curl -s -o /dev/null -w '%{http_code}\n' http://envoy:8080$1; done" \
    | sort | uniq -c | awk '{ printf "%s×%s ", $1, $2 }' | sed 's/ $//'
}

verify() {
  client_ready
  say "1. how Envoy finds endpoints"
  assert "STATIC: the sidecar on localhost" "127.0.0.1:8081" "$(members static_sidecar)"
  assert "STRICT_DNS, headless Service: one endpoint per pod" "3" "$(members headless | grep -c .)"
  VIP=$($KUBE get svc echo-vip -n "$NS" -o jsonpath='{.spec.clusterIP}')
  assert "STRICT_DNS, ClusterIP Service: one endpoint, the virtual IP" "$VIP:8080" "$(members vip)"
  assert "LOGICAL_DNS: only the first address" "1" "$(members logical | grep -c .)"
  assert_contains "the sidecar answers from inside the Envoy pod" '"served_by": "envoy-' \
    "$(incluster_curl "http://envoy.$NS.svc:8080/static")"

  say "2. EDS: endpoints delivered from a file, no restart"
  ./write-eds.sh >/dev/null
  N=0
  for _ in $(seq 1 60); do
    N=$(members eds | grep -c .); [ "$N" -eq 3 ] && break; sleep 2
  done
  assert "Envoy loaded the 3 endpoints written by write-eds.sh" "3" "$N"

  say "3. how Envoy chooses between endpoints"
  assert "ROUND_ROBIN on one worker thread: an exact 20/20/20" "20 20 20" \
    "$(spread /headless 60 envoy-single)"
  assert "LOGICAL_DNS: all 60 requests to one pod" "60" "$(spread /logical 60)"
  STICKY=$(incluster_sh "for i in \$(seq 1 10); do curl -s -H 'x-user: alice' http://envoy:8080/ring-hash | grep -o 'echo-[a-z0-9]*-[a-z0-9]*'; done" | sort -u | wc -l | tr -d ' ')
  assert "RING_HASH: one user, 10 requests, one pod" "1" "$STICKY"

  say "4. health checks"
  SICK=$($KUBE get pod -n "$NS" -l app=sick -o jsonpath='{.items[0].status.podIP}')
  assert_contains "Envoy's health check flags the sick pod" "failed_active_hc" \
    "$(incluster_curl "http://envoy.$NS.svc:9901/clusters" | grep "^checked::$SICK:")"
  assert "with the health check, 60 of 60 succeed" "60×200" "$(codes /checked 60)"
  assert_contains "without it, the sick pod still gets traffic" "×503" "$(codes /unchecked 60)"
  summary
}

clean() { $KUBE delete ns "$NS" --wait=false >/dev/null 2>&1; ok "namespace $NS deleting"; }

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
