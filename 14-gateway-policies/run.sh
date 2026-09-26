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
  ns_settle "$NS"
  $KUBE apply -f manifests/10-gateway.yaml >/dev/null || { bad "could not create the Gateway in $NS"; exit 1; }
  gw_up "$NS" eg
  $KUBE apply -n "$NS" -f ../_shared/client.yaml -f ../_shared/echo-app.yaml -f manifests/20-pool.yaml \
    -f manifests/30-sick-app.yaml -f manifests/35-slow-app.yaml -f manifests/40-routes.yaml >/dev/null
  $KUBE apply -f manifests/55-retry-and-eject.yaml -f manifests/60-circuit-breaker.yaml \
    -f manifests/70-rate-limit.yaml -f manifests/80-jwt-cors.yaml \
    -f manifests/85-routes-part-b.yaml -f manifests/91-fault-delay.yaml -f manifests/95-consistent-hash.yaml >/dev/null
  wait_ready echo; wait_ready good; wait_ready sick; wait_ready slow
  ok "Gateway eg programmed at $(gw_address "$NS" eg)"
}

admin() { ../_shared/eg-admin.sh "$NS/eg" "$1"; }
# overflows - how many requests /slow's circuit breaker has refused so far:
# Envoy counts one over max_requests as upstream_rq_active_overflow, one over
# max_pending_requests as upstream_rq_pending_overflow.
overflows() {
  admin "stats?filter=^cluster\.httproute/$NS/slow/rule/0\.upstream_rq_(active|pending)_overflow\$" \
    | awk -F': ' '{ n += $2 } END { print n + 0 }'
}
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
  for p in backendtrafficpolicy/pool backendtrafficpolicy/slow backendtrafficpolicy/api securitypolicy/api \
           backendtrafficpolicy/chaos backendtrafficpolicy/sticky; do
    assert "$p accepted" "True" "$(accepted "$p")"
  done

  say "2. retry and passive health check on /pool (two good pods, one sick)"
  assert "90 requests, 90 succeed" "90×200" \
    "$(incluster_sh "for i in \$(seq 1 90); do curl -s -o /dev/null -w '%{http_code}\n' http://$ADDR/pool; done" \
       | sort | uniq -c | awk '{ printf "%s×%s ", $1, $2 }' | sed 's/ $//')"
  assert_contains "Envoy Gateway added previous_hosts to the retry" "envoy.retry_host_predicates.previous_hosts" \
    "$(admin 'config_dump?resource=dynamic_route_configs')"
  SICK=$($KUBE get pod -n "$NS" -l app=sick -o jsonpath='{.items[0].status.podIP}')
  F=$(admin clusters | grep "^httproute/$NS/pool/rule/0::$SICK:8080::health_flags::")
  # An ejection lasts 30 s (longer when repeated) and ends on Envoy's 1 s
  # timer, so it can end between the 90 requests above and this read: seen in
  # 2 of 37 back-to-back verify runs. Then 30 more requests reach the sick pod,
  # and two 5xx in a row eject it again at once.
  case "$F" in
    (*failed_outlier_check*) ;;
    (*) incluster_sh "for i in \$(seq 1 30); do curl -s -o /dev/null http://$ADDR/pool; done"
        F=$(admin clusters | grep "^httproute/$NS/pool/rule/0::$SICK:8080::health_flags::") ;;
  esac
  assert_contains "the sick pod is ejected" "failed_outlier_check" "$F"

  say "3. circuit breaker on /slow (2 in flight, 2 waiting)"
  BEFORE=$(overflows)
  B=$(incluster_sh "seq 1 10 | xargs -P 10 -I{} curl -s -o /dev/null -w '%{http_code} %{time_total}\n' http://$ADDR/slow")
  AFTER=$(overflows)
  OK=$(printf '%s\n' "$B" | awk '$1 == 200' | wc -l | tr -d ' ')
  REFUSED=$(printf '%s\n' "$B" | awk '$1 == 503' | wc -l | tr -d ' ')
  echo "  10 at once: $OK answered, $REFUSED refused"
  # A limit of 2, yet sometimes 3 to 5 answered: Envoy's worker threads share
  # the counter and can race past it - "races between threads may allow limits
  # to be potentially exceeded" (Envoy's circuit breaking docs). Measured over
  # 60 bursts: 2 answered 38 times, 3 20 times, 4 once, 5 once. Without the
  # breaker all 10 are answered.
  assert "2 to 6 answered" "yes" "$([ "$OK" -ge 2 ] && [ "$OK" -le 6 ] && echo yes || echo no)"
  assert "the other requests were refused with 503" "10" "$((OK + REFUSED))"
  assert "...each one counted by Envoy as a circuit-breaker overflow" "yes" \
    "$([ "$REFUSED" -gt 0 ] && [ "$((AFTER - BEFORE))" -eq "$REFUSED" ] && echo yes || echo no)"
  # "At once" needs a refusal to time: no 503 at all is a failure, not a pass.
  assert "every refusal came back at once" "yes" \
    "$(printf '%s\n' "$B" | awk '$1 == 503 { n++; if ($2 >= 0.5) slow = 1 } END { print (n && !slow) ? "yes" : "no" }')"

  say "4. JWT on /api"
  assert_contains "no token -> 401"     "Jwt is missing"          "$(incluster_curl "http://$ADDR/api")"
  assert_contains "forged token -> 401" "Jwt verification fails" \
    "$(incluster_curl -H "authorization: Bearer $(../06-http-filters/make-jwt.sh alice forged)" "http://$ADDR/api")"
  R=$(api_as_alice)
  assert_contains "alice -> 200"                         "200 OK"          "$R"
  assert_contains "the app is told the verified subject" '"x-user": "alice"' "$R"

  say "5. rate limit on /api (3 a minute)"
  # Five requests in a row; keep each one's headers for the second check.
  RL=$(incluster_sh "for i in 1 2 3 4 5; do curl -s -o /dev/null -D - -H 'authorization: Bearer $TOKEN' http://$ADDR/api; done" | tr -d '\r')
  CODES=$(printf '%s\n' "$RL" | awk '/^HTTP\// { printf "%s ", $2 }')
  echo "  5 requests in a row: $CODES"
  assert "at least 2 of 5 refused with 429" "yes" \
    "$([ "$(printf '%s' "$CODES" | tr ' ' '\n' | grep -c '^429$')" -ge 2 ] && echo yes || echo no)"
  # A 200 carries x-ratelimit-limit too: the check is that a 429 does.
  assert "a 429 says the limit" "3" \
    "$(printf '%s\n' "$RL" | awk '/^HTTP\// { c = $2 } c == 429 && tolower($1) == "x-ratelimit-limit:" { print $2; exit }')"

  say "6. CORS on /api"
  PRE="-X OPTIONS -H 'access-control-request-method: POST'"
  assert_contains "shop.example.com may call it" "access-control-allow-origin: https://shop.example.com" \
    "$(incluster_sh "curl -s -o /dev/null -D - $PRE -H 'origin: https://shop.example.com' http://$ADDR/api")"
  # The CORS filter answers this preflight itself - a 200 - and leaves out
  # access-control-allow-origin. An empty or failed answer lacks the header
  # too, so the status is part of the check.
  assert "another origin is not allowed" "200 no-origin" \
    "$(incluster_sh "curl -s -o /dev/null -D - $PRE -H 'origin: https://evil.example.com' http://$ADDR/api" | tr -d '\r' \
       | awk '/^HTTP\// { c = $2 } tolower($1) == "access-control-allow-origin:" { o = 1 } END { print c, (o ? "origin" : "no-origin") }')"

  say "7. fault injection on /chaos"
  # Abort first (a route change: seconds), then back to the delay deploy left.
  $KUBE apply -f manifests/90-fault-abort.yaml >/dev/null
  ABORTS=0
  for _ in $(seq 1 20); do
    ABORTS=$(incluster_sh "for i in \$(seq 1 50); do curl -s http://$ADDR/chaos; echo; done" | grep -c 'fault filter abort')
    [ "$ABORTS" -gt 0 ] && break; sleep 2
  done
  echo "  abort 30 %: $ABORTS of 50 aborted"
  # 50 requests at 30 %: 15 expected; none at all is 0.7^50, about 2 in 100 million.
  assert "the proxy aborted some, saying 'fault filter abort'" "yes" "$([ "$ABORTS" -gt 0 ] && echo yes || echo no)"
  $KUBE apply -f manifests/91-fault-delay.yaml >/dev/null
  T=0
  for _ in $(seq 1 20); do
    T=$(incluster_curl -o /dev/null -w '%{time_total}' "http://$ADDR/chaos")
    awk -v t="$T" 'BEGIN { exit !(t >= 1.9) }' && break; sleep 2
  done
  assert "with the delay, a request takes about 2 s" "yes" "$(awk -v t="$T" 'BEGIN { print (t >= 1.9 && t < 3) ? "yes" : "no" }')"

  say "8. consistent hashing on /sticky"
  for u in alice bob carol; do
    assert "$u: 10 requests, one pod" "1" \
      "$(incluster_sh "for i in \$(seq 1 10); do curl -s -H 'x-user: $u' http://$ADDR/sticky | grep -o 'echo-[a-z0-9]*-[a-z0-9]*'; done" | sort -u | grep -c .)"
  done
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
