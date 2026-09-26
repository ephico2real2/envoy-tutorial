#!/usr/bin/env bash
# Module 13 — HTTPRoute traffic management.  ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=envoy-13
. ../_shared/lib.sh
. ../_shared/gateway.sh

ROUTES="main split rewrite-redirect mirror slow"

deploy() {
  say "deploying into $NS"
  # Module 12's GatewayClass and EnvoyProxy - the cluster operator's part.
  $KUBE apply -f ../12-gateway-api/manifests/20-envoyproxy.yaml -f ../12-gateway-api/manifests/10-gatewayclass.yaml >/dev/null
  $KUBE wait gatewayclass/eg --for=condition=Accepted --timeout=60s >/dev/null
  $KUBE apply -f manifests/10-gateway.yaml >/dev/null
  gw_up "$NS" eg
  $KUBE apply -n "$NS" -f ../_shared/client.yaml -f ../_shared/echo-app.yaml \
    -f manifests/20-canary.yaml -f manifests/30-slow-app.yaml >/dev/null
  $KUBE apply -f manifests/40-route-main.yaml -f manifests/50-route-split.yaml \
    -f manifests/60-route-rewrite-redirect.yaml -f manifests/70-route-mirror.yaml \
    -f manifests/80-route-timeout.yaml >/dev/null
  wait_ready echo; wait_ready canary; wait_ready slow
  ok "Gateway eg programmed at $(gw_address "$NS" eg)"
}

# served <path> [curl args...] - which Deployment answered: echo or canary.
served() {
  local path=$1; shift
  incluster_curl "$@" "http://$ADDR$path" | sed -n 's/.*"served_by": "\([a-z]*\)-.*/\1/p'
}

verify() {
  client_ready
  ADDR=$(gw_address "$NS" eg)
  [ -n "$ADDR" ] || { bad "Gateway eg has no address"; summary; exit 1; }

  say "1. the Gateway API objects"
  assert "Gateway programmed" "True" \
    "$($KUBE get gateway eg -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')"
  for r in $ROUTES; do
    assert "HTTPRoute $r accepted" "True" \
      "$($KUBE get httproute "$r" -n "$NS" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')"
  done

  say "2. precedence: the most specific match wins, whatever the rule order"
  assert "/ -> echo"                        "echo"   "$(served /)"
  assert "/canary/x -> canary"              "canary" "$(served /canary/x)"
  assert "/canaryfoo -> echo (whole path segments only)" "echo" "$(served /canaryfoo)"
  assert "x-canary: yes -> canary"          "canary" "$(served /anything -H 'x-canary: yes')"
  # The catch-all rule was written first; the controller hands it to Envoy last.
  LAST=$(../_shared/eg-admin.sh "$NS/eg" 'config_dump?resource=dynamic_route_configs' | python3 -c '
import json, sys
routes = [r for rc in json.load(sys.stdin)["configs"] for vh in rc["route_config"]["virtual_hosts"] for r in vh["routes"]]
print(routes[-1]["route"]["cluster"])')
  assert "the catch-all is the LAST route Envoy gets" "httproute/$NS/main/rule/0" "$LAST"

  say "3. a weighted split, 90/10"
  CANARY=$(incluster_sh "for i in \$(seq 1 200); do curl -s http://$ADDR/split; done" | grep -c '"served_by": "canary-')
  echo "  canary answered $CANARY of 200"
  # 200 requests at 10 %: 20 expected, standard deviation 4.2. 5 to 40 is
  # more than 3.5 deviations either way.
  assert "the canary got about 10 % (5 to 40 of 200)" "yes" \
    "$([ "$CANARY" -ge 5 ] && [ "$CANARY" -le 40 ] && echo yes || echo no)"

  say "4. rewrite and redirect"
  assert_contains "/v2/hello reaches the canary as /hello" '"path": "/hello"' "$(incluster_curl "http://$ADDR/v2/hello")"
  R=$(incluster_curl -o /dev/null -D - "http://$ADDR/old/page")
  assert_contains "/old/page -> 301"              "301"            "$R"
  assert_contains "...pointing at /new/page"      "/new/page"      "$R"

  say "5. mirror: the canary gets a copy, the client gets the stable answer"
  MARK="/mirror/verify-$RANDOM$RANDOM"
  assert "the client's answer came from echo" "echo" "$(served "$MARK")"
  SEEN=no
  for _ in $(seq 1 10); do
    $KUBE logs -n "$NS" deploy/canary --tail=50 | grep -qF "GET $MARK" && { SEEN=yes; break; }
    sleep 1
  done
  assert "the canary logged the copy" "yes" "$SEEN"

  say "6. a route timeout"
  T=$(incluster_curl -o /dev/null -w '%{http_code} %{time_total}' "http://$ADDR/slow")
  echo "  /slow answered ${T%% *} after ${T#* }s"
  assert "/slow -> 504" "504" "${T%% *}"
  # curl's clock and Envoy's differ slightly: measured, 15 timeouts took
  # 0.495 to 0.510 s. The app itself takes 1 s.
  assert "...after the 500 ms timeout, not the app's 1 s" "yes" \
    "$(awk -v t="${T#* }" 'BEGIN { print (t >= 0.45 && t < 0.9) ? "yes" : "no" }')"
  summary
}

clean() {
  gw_down "$NS" eg
  # The Gateway lives in the namespace; deleting it removes the generated Envoy.
  $KUBE delete -f manifests/10-gateway.yaml --ignore-not-found --wait=false >/dev/null 2>&1
  ok "namespace $NS deleting (module 12's GatewayClass eg is left for other modules)"
}

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
