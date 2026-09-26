#!/usr/bin/env bash
# Module 06 — HTTP filters and their order.  ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=envoy-06
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

# A new Envoy starts with full rate-limit buckets, so the order experiment
# begins from a known state rather than whatever earlier checks left behind.
restart_envoy() {
  $KUBE delete pod -n "$NS" -l app=envoy --wait=true >/dev/null
  wait_ready envoy
  wait_upstream echo_service
}

# codes10 <port> [curl args] - ten requests, their status codes in order.
codes10() {
  incluster_sh "for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null -w '%{http_code} ' ${2:-} http://envoy:$1/; done" | sed 's/ $//'
}

verify() {
  client_ready
  TOKEN=$(./make-jwt.sh alice)
  FORGED=$(./make-jwt.sh alice forged)

  say "1. jwt_authn"
  R=$(incluster_curl -i "http://envoy.$NS.svc:8080/")
  assert_contains "no token -> 401" "401" "$R"
  assert_contains "no token -> 'Jwt is missing'" "Jwt is missing" "$R"
  assert_contains "forged token -> 'Jwt verification fails'" "Jwt verification fails" \
    "$(incluster_curl -H "Authorization: Bearer $FORGED" "http://envoy.$NS.svc:8080/")"
  OK=$(incluster_curl -H "Authorization: Bearer $TOKEN" "http://envoy.$NS.svc:8080/")
  assert_contains "valid token reaches the app"      '"served_by"'       "$OK"
  assert_contains "the sub claim arrives as x-user"  '"x-user": "alice"' "$OK"
  assert "the token itself is not forwarded" "0" "$(printf '%s' "$OK" | grep -c '"authorization"')"

  say "2. filters run in the order written"
  assert_contains "trace-a ran before trace-b" '"x-filter-trace": "trace-a,trace-b"' "$OK"

  say "3. cors answers the preflight before jwt_authn can reject it"
  P=$(incluster_curl -i -X OPTIONS -H 'Origin: https://shop.example' \
        -H 'Access-Control-Request-Method: POST' "http://envoy.$NS.svc:8080/")
  assert_contains "allowed origin: 200 with no token" "200 OK" "$P"
  assert_contains "allowed origin: CORS headers" "access-control-allow-origin: https://shop.example" \
    "$(printf '%s' "$P" | tr 'A-Z' 'a-z')"
  assert_contains "disallowed origin: not answered by cors, so jwt_authn says 401" "401" \
    "$(incluster_curl -i -X OPTIONS -H 'Origin: https://evil.example' \
         -H 'Access-Control-Request-Method: POST' "http://envoy.$NS.svc:8080/")"

  say "4. the order of jwt_authn and local_ratelimit"
  restart_envoy
  assert "auth first (:8080): 10 unsigned requests"  "401 401 401 401 401 401 401 401 401 401" "$(codes10 8080)"
  assert "auth first (:8080): then alice gets through" "200" \
    "$(incluster_curl -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "http://envoy.$NS.svc:8080/")"
  assert "limit first (:8081): 10 unsigned requests" "401 401 401 401 401 429 429 429 429 429" "$(codes10 8081)"
  assert "limit first (:8081): alice is rate limited" "429" \
    "$(incluster_curl -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "http://envoy.$NS.svc:8081/")"
  summary
}

clean() { $KUBE delete ns "$NS" --wait=false >/dev/null 2>&1; ok "namespace $NS deleting"; }

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
