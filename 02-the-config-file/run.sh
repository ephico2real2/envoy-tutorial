#!/usr/bin/env bash
# Module 02 — the config file, field by field.  ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=envoy-02
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
  say "the fields are actually in effect, not just in the file"

  R=$(incluster_curl -i "http://envoy.$NS.svc:8080/fields")
  # server_header_transformation: OVERWRITE + server_name
  assert_contains "Server header rewritten to server_name" "server: tutorial-gateway" \
    "$(printf '%s' "$R" | tr 'A-Z' 'a-z')"
  # Envoy tells the BACKEND the deadline it is enforcing, in a REQUEST header -
  # so it shows up in the echoed body, not in the response headers.
  #
  # The value is 2000, which is neither the listener's request_timeout (10s)
  # nor the route's timeout (5s): it is per_try_timeout. With a retry policy,
  # the deadline that matters to the backend is the one for THIS attempt,
  # because Envoy may give up on it and try another endpoint while the 5s
  # route budget is still running.
  assert_contains "backend is told the per-try deadline (2s), not the route's 5s" \
    '"x-envoy-expected-rq-timeout-ms": "2000"' "$R"

  say "the access log is JSON with the fields we asked for"
  # Access logs are buffered and a pod that just restarted has none yet, so
  # retry rather than assert once. A flaky check teaches the reader to ignore
  # failures, which is worse than having no check.
  LOG=""
  for _ in $(seq 1 15); do
    incluster_curl "http://envoy.$NS.svc:8080/logcheck" >/dev/null 2>&1
    LOG=$($KUBE logs -n "$NS" deploy/envoy --tail=60 2>/dev/null | grep logcheck | tail -1)
    [ -n "$LOG" ] && break
    sleep 2
  done
  [ -z "$LOG" ] && { bad "no access log line for /logcheck after 30s"; FAILED=$((FAILED+1)); }
  for k in start method path protocol code flags duration upstream req_id; do
    assert_contains "log has \"$k\"" "\"$k\"" "$LOG"
  done

  say "circuit breakers are registered with the values we set"
  CB=$(incluster_curl "http://envoy.$NS.svc:9901/config_dump")
  assert_contains "max_connections 100"      '"max_connections": 100'      "$CB"
  assert_contains "max_pending_requests 50"  '"max_pending_requests": 50'  "$CB"
  assert_contains "max_requests 200"         '"max_requests": 200'         "$CB"

  say "the retry policy is live"
  assert_contains "retry_on set"   'connect-failure' "$CB"
  assert_contains "num_retries 2"  '"num_retries": 2' "$CB"

  say "node identity reaches the stats"
  S=$(incluster_curl "http://envoy.$NS.svc:9901/server_info")
  assert_contains "node id" "tutorial-envoy" "$S"
  summary
}

clean() { $KUBE delete ns "$NS" --wait=false >/dev/null 2>&1; ok "namespace $NS deleting"; }

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
