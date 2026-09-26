#!/usr/bin/env bash
# Module 01 — what Envoy is.  ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=envoy-01
. ../_shared/lib.sh

deploy() {
  say "deploying into $NS"
  ns_ensure
  $KUBE apply -n "$NS" -f ../_shared/echo-app.yaml >/dev/null
  $KUBE apply -n "$NS" -f manifests/ >/dev/null
  wait_ready echo; wait_ready envoy
  wait_upstream echo_service
  ok "echo and envoy are up"
}

verify() {
  say "1. the backend is reachable directly (no Envoy involved)"
  DIRECT=$(incluster_curl "http://echo.$NS.svc:8080/direct")
  assert_contains "echo answers on its own" '"served_by"' "$DIRECT"
  assert_contains "no proxy fingerprint"    "false" \
    "$(case "$DIRECT" in (*x-envoy*) echo true ;; (*) echo false ;; esac)"

  say "2. the same request through Envoy"
  VIA=$(incluster_curl "http://envoy.$NS.svc:8080/direct")
  assert_contains "still reaches the backend" '"served_by"' "$VIA"
  # These headers are the whole lesson: the app did not set them, so their
  # presence is proof something sat in the middle.
  assert_contains "x-forwarded-for added"        "x-forwarded-for"  "$VIA"
  assert_contains "x-request-id added"           "x-request-id"     "$VIA"
  assert_contains "x-envoy-expected-rq-timeout"  "x-envoy"          "$VIA"

  say "3. the four nouns, from Envoy's own admin interface"
  for pair in "listener:http_listener" "cluster:echo_service"; do
    kind=${pair%%:*}; name=${pair#*:}
    n=$(incluster_curl "http://envoy.$NS.svc:9901/config_dump" | grep -c "$name")
    [ "$n" -gt 0 ] && ok "$kind $name is in the running config" \
                   || { bad "$kind $name missing from config_dump"; FAILED=$((FAILED+1)); }
  done

  say "4. Envoy is load balancing, not just forwarding"
  # The helper passes its arguments to curl, so a shell loop needs its own pod.
  SEEN=$($KUBE run lb-$RANDOM -n "$NS" --rm -i --restart=Never --quiet \
           --image=curlimages/curl:8.11.1 --command -- \
           sh -c "for i in \$(seq 1 12); do curl -s http://envoy.$NS.svc:8080/; done" 2>/dev/null \
         | grep served_by | sort -u | wc -l | tr -d ' ')
  [ "${SEEN:-0}" -ge 2 ] && ok "reached $SEEN distinct backend pods over 12 requests" \
                         || { bad "only ${SEEN:-0} pod(s) answered — expected 2"; FAILED=$((FAILED+1)); }
  summary
}

clean() { $KUBE delete ns "$NS" --wait=false >/dev/null 2>&1; ok "namespace $NS deleting"; }

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
