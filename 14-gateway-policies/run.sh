#!/usr/bin/env bash
# Module 14 — Envoy Gateway policies.  ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=envoy-14
. ../_shared/lib.sh
. ../_shared/gateway.sh

deploy() {
  say "deploying into $NS"
  # Module 12's GatewayClass and EnvoyProxy - the cluster operator's part.
  $KUBE apply -f ../12-gateway-api/manifests/20-envoyproxy.yaml -f ../12-gateway-api/manifests/10-gatewayclass.yaml >/dev/null
  $KUBE wait gatewayclass/eg --for=condition=Accepted --timeout=60s >/dev/null
  $KUBE apply -f manifests/10-gateway.yaml >/dev/null
  gw_up "$NS" eg
  $KUBE apply -n "$NS" -f ../_shared/client.yaml -f ../_shared/echo-app.yaml -f manifests/20-pool.yaml \
    -f manifests/30-sick-app.yaml -f manifests/35-slow-app.yaml -f manifests/40-routes.yaml >/dev/null
  $KUBE apply -f manifests/55-retry-and-eject.yaml -f manifests/60-circuit-breaker.yaml \
    -f manifests/70-rate-limit.yaml -f manifests/80-jwt-cors.yaml >/dev/null
  wait_ready echo; wait_ready good; wait_ready sick; wait_ready slow
  ok "Gateway eg programmed at $(gw_address "$NS" eg)"
}

admin() { ../_shared/eg-admin.sh "$NS/eg" "$1"; }
stat() { admin "stats?filter=^$1\$" | awk -F': ' '{ print $2 }'; }
accepted() {
  $KUBE get "$1" -n "$NS" -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}'
}
# api_as_alice [curl args...] - /api with alice's token. The rate limit (3 a
# minute, one token back every 20 s) may be spent by an earlier run: on a 429,
# wait for the next token rather than fail.
api_as_alice() {
  local out
  for _ in 1 2 3; do
    out=$(incluster_curl -i -H "authorization: Bearer $TOKEN" "$@" "http://$ADDR/api")
    case "$out" in (*" 429 "*) sleep 21 ;; (*) break ;; esac
  done
  printf '%s' "$out"
}

verify() {
  client_ready
  ADDR=$(gw_address "$NS" eg)
  [ -n "$ADDR" ] || { bad "Gateway eg has no address"; summary; exit 1; }
  TOKEN=$(../06-http-filters/make-jwt.sh alice)

  say "1. the policies"
  for p in backendtrafficpolicy/pool backendtrafficpolicy/slow backendtrafficpolicy/api securitypolicy/api; do
    assert "$p accepted" "True" "$(accepted "$p")"
  done

  say "2. retry and passive health check on /pool (two good pods, one sick)"
  assert "90 requests, 90 succeed" "90×200" \
    "$(incluster_sh "for i in \$(seq 1 90); do curl -s -o /dev/null -w '%{http_code}\n' http://$ADDR/pool; done" \
       | sort | uniq -c | awk '{ printf "%s×%s ", $1, $2 }' | sed 's/ $//')"
  assert_contains "Envoy Gateway added previous_hosts to the retry" "envoy.retry_host_predicates.previous_hosts" \
    "$(admin 'config_dump?resource=dynamic_route_configs')"
  SICK=$($KUBE get pod -n "$NS" -l app=sick -o jsonpath='{.items[0].status.podIP}')
  assert_contains "the sick pod is ejected" "failed_outlier_check" \
    "$(admin clusters | grep "^httproute/$NS/pool/rule/0::$SICK:8080::health_flags::")"

  say "3. circuit breaker on /slow (2 in flight, 2 waiting)"
  B=$(incluster_sh "seq 1 10 | xargs -P 10 -I{} curl -s -o /dev/null -w '%{http_code} %{time_total}\n' http://$ADDR/slow")
  OK=$(printf '%s\n' "$B" | awk '$1 == 200' | wc -l | tr -d ' ')
  REFUSED=$(printf '%s\n' "$B" | awk '$1 == 503' | wc -l | tr -d ' ')
  echo "  10 at once: $OK answered, $REFUSED refused"
  assert "2 to 4 answered" "yes" "$([ "$OK" -ge 2 ] && [ "$OK" -le 4 ] && echo yes || echo no)"
  assert "the other requests were refused with 503" "10" "$((OK + REFUSED))"
  assert "every refusal came back at once" "yes" \
    "$(printf '%s\n' "$B" | awk '$1 == 503 && $2 >= 0.5 { slow = 1 } END { print slow ? "no" : "yes" }')"

  say "4. JWT on /api"
  assert_contains "no token -> 401"     "Jwt is missing"          "$(incluster_curl "http://$ADDR/api")"
  assert_contains "forged token -> 401" "Jwt verification fails" \
    "$(incluster_curl -H "authorization: Bearer $(../06-http-filters/make-jwt.sh alice forged)" "http://$ADDR/api")"
  R=$(api_as_alice)
  assert_contains "alice -> 200"                         "200 OK"          "$R"
  assert_contains "the app is told the verified subject" '"x-user": "alice"' "$R"

  say "5. rate limit on /api (3 a minute)"
  CODES=$(incluster_sh "for i in 1 2 3 4 5; do curl -s -o /dev/null -w '%{http_code}\n' -H 'authorization: Bearer $TOKEN' http://$ADDR/api; done" | tr '\n' ' ')
  echo "  5 requests at once: $CODES"
  assert "at least 2 of 5 refused with 429" "yes" \
    "$([ "$(printf '%s' "$CODES" | tr ' ' '\n' | grep -c '^429$')" -ge 2 ] && echo yes || echo no)"
  assert_contains "a 429 says the limit" "x-ratelimit-limit: 3" \
    "$(incluster_curl -i -H "authorization: Bearer $TOKEN" "http://$ADDR/api")"

  say "6. CORS on /api"
  PRE="-X OPTIONS -H 'access-control-request-method: POST'"
  assert_contains "shop.example.com may call it" "access-control-allow-origin: https://shop.example.com" \
    "$(incluster_sh "curl -s -o /dev/null -D - $PRE -H 'origin: https://shop.example.com' http://$ADDR/api")"
  assert "another origin is not allowed" "0" \
    "$(incluster_sh "curl -s -o /dev/null -D - $PRE -H 'origin: https://evil.example.com' http://$ADDR/api" | grep -ci '^access-control-allow-origin')"
  summary
}

clean() {
  gw_down "$NS" eg
  $KUBE delete -f manifests/10-gateway.yaml --ignore-not-found --wait=false >/dev/null 2>&1
  ok "namespace $NS deleting (module 12's GatewayClass eg is left for other modules)"
}

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
