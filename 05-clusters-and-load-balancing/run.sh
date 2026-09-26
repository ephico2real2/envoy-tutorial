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
  # All three, not just one: the Envoys started while the echo pods were still
  # coming up, and STRICT_DNS catches up only at a later re-resolution (every
  # 5 s, of a DNS answer cached for 5 s) - a split measured before then covers
  # two pods, not three.
  wait_members headless envoy 3
  wait_members headless envoy-single 3
  ok "echo (3), sick, envoy and envoy-single are up"
}

# members <cluster> [envoy-service] - the endpoint addresses Envoy holds for a cluster.
members() {
  incluster_curl "http://${2:-envoy}.$NS.svc:9901/clusters" \
    | awk -F'::' -v c="$1" '$1 == c && $3 == "health_flags" { print $2 }' | sort
}
# wait_members <cluster> <envoy-service> <n> - until that Envoy holds n endpoints for the cluster.
wait_members() {
  client_ready
  for _ in $(seq 1 30); do
    if [ "$(members "$1" "$2" | grep -c .)" -eq "$3" ]; then ok "$2 holds all $3 $1 endpoints"; return 0; fi
    sleep 2
  done
  bad "$2 never held $3 $1 endpoints"; exit 1
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
# from_sick <path> <n> - how many of n requests the sick pod itself answered. Its
# body names it; Envoy's own 503s ("no healthy upstream", "upstream connect
# error") do not, so they cannot stand in for it.
from_sick() {
  incluster_sh "for i in \$(seq 1 $2); do curl -s http://envoy:8080$1; echo; done" | grep -c '^503 from sick-'
}

verify() {
  client_ready
  say "1. how Envoy finds endpoints"
  assert "STATIC: the sidecar on localhost" "127.0.0.1:8081" "$(members static_sidecar)"
  assert "STRICT_DNS, headless Service: one endpoint per pod" "3" "$(members headless | grep -c .)"
  VIP=$($KUBE get svc echo-vip -n "$NS" -o jsonpath='{.spec.clusterIP}')
  assert "STRICT_DNS, ClusterIP Service: one endpoint, the virtual IP" "$VIP:8080" "$(members vip)"
  # LOGICAL_DNS holds at most one address by construction, so a count alone
  # cannot fail; the address must also be one of the pods DNS returned.
  LOGICAL=$(members logical)
  case " $(members headless | tr '\n' ' ') " in
    (*" $LOGICAL "*) LOGICAL_OK=yes ;; (*) LOGICAL_OK=no ;;
  esac
  assert "LOGICAL_DNS: one endpoint, one of the pod IPs" "1 yes" "$(printf '%s\n' "$LOGICAL" | grep -c .) $LOGICAL_OK"
  assert_contains "the sidecar answers from inside the Envoy pod" '"served_by": "envoy-' \
    "$(incluster_curl "http://envoy.$NS.svc:8080/static")"

  say "2. EDS: endpoints delivered from a file, no restart"
  # Compare addresses, not a count: three stale endpoints from an earlier run
  # count as three too, and a failed write-eds.sh must not pass.
  if WANT=$(./write-eds.sh | sed -n 's/^  \([0-9.]*:[0-9]*\)$/\1/p' | sort) && [ -n "$WANT" ]; then
    GOT=
    for _ in $(seq 1 60); do
      GOT=$(members eds); [ "$GOT" = "$WANT" ] && break; sleep 2
    done
    assert "Envoy loaded exactly the endpoints write-eds.sh wrote" "$(echo $WANT)" "$(echo $GOT)"
  else
    bad "write-eds.sh failed - nothing to check"; FAILED=$((FAILED+1))
  fi

  say "3. how Envoy chooses between endpoints"
  assert "ROUND_ROBIN on one worker thread: an exact 20/20/20" "20 20 20" \
    "$(spread /headless 60 envoy-single)"
  # LOGICAL_DNS follows whichever address DNS lists first. A DNS server that
  # shuffles its answers (the loadbalance plugin - kind's CoreDNS has it) can
  # move it during the 60 requests, so one retry before calling it a failure.
  LOGICAL_SPREAD=$(spread /logical 60)
  [ "$LOGICAL_SPREAD" = 60 ] || LOGICAL_SPREAD=$(spread /logical 60)
  assert "LOGICAL_DNS: all 60 requests to one pod" "60" "$LOGICAL_SPREAD"
  # All 10 must be answered: failed requests print nothing and would vanish.
  STICKY=$(incluster_sh "for i in \$(seq 1 10); do curl -s -H 'x-user: alice' http://envoy:8080/ring-hash | grep -o 'echo-[a-z0-9]*-[a-z0-9]*'; done" | sort | uniq -c | awk '{ print $1 }' | tr '\n' ' ' | sed 's/ $//')
  assert "RING_HASH: one user, 10 requests, one pod" "10" "$STICKY"

  say "4. health checks"
  SICK=$($KUBE get pod -n "$NS" -l app=sick -o jsonpath='{.items[0].status.podIP}')
  assert_contains "Envoy's health check flags the sick pod" "failed_active_hc" \
    "$(incluster_curl "http://envoy.$NS.svc:9901/clusters" | grep "^checked::$SICK:")"
  assert "with the health check, 60 of 60 succeed" "60×200" "$(codes /checked 60)"
  N_SICK=$(from_sick /unchecked 60)
  assert "without it, the sick pod still answers some of 60" "yes" \
    "$([ "$N_SICK" -gt 0 ] && echo yes || echo "no - $N_SICK")"
  summary
}

clean() { $KUBE delete ns "$NS" --wait=false >/dev/null 2>&1; ok "namespace $NS deleting"; }

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
