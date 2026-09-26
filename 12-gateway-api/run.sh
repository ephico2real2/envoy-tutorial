#!/usr/bin/env bash
# Module 12 — the Gateway API.  ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=gwapi-demo
. ../_shared/lib.sh

GW_NS=envoy-gateway-system
GW_LABEL=gateway.envoyproxy.io/owning-gateway-name=eg,gateway.envoyproxy.io/owning-gateway-namespace=$NS
ROUTE_HOST=gwapi-demo.apps-crc.testing

has_routes() { $KUBE api-resources --api-group=route.openshift.io 2>/dev/null | grep -q '^routes'; }
has_sccs()   { $KUBE api-resources --api-group=security.openshift.io 2>/dev/null | grep -q '^securitycontextconstraints'; }
# The ServiceAccount of the Envoy that Envoy Gateway generated for this Gateway.
proxy_sa() { $KUBE get deploy -n "$GW_NS" -l "$GW_LABEL" -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}' 2>/dev/null; }

deploy() {
  say "deploying"
  # clean deletes the namespace with --wait=false, and nothing can be created in
  # a namespace that is still Terminating: wait until it is gone.
  for _ in $(seq 1 60); do
    [ "$($KUBE get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)" = Terminating ] || break
    sleep 2
  done
  $KUBE apply -f manifests/20-envoyproxy.yaml -f manifests/10-gatewayclass.yaml >/dev/null
  $KUBE wait gatewayclass/eg --for=condition=Accepted --timeout=60s >/dev/null
  $KUBE apply -f manifests/30-gateway.yaml >/dev/null
  # The controller generates the proxy Deployment a moment after the Gateway exists.
  for _ in $(seq 1 30); do [ -n "$(proxy_sa)" ] && break; sleep 2; done
  [ -n "$(proxy_sa)" ] || { bad "Envoy Gateway generated no proxy Deployment for $NS/eg"; exit 1; }
  if has_sccs; then
    # Per-Gateway: each Gateway's Envoy runs as its own ServiceAccount. The
    # restart gets a pod created now, not after the ReplicaSet's retry back-off.
    $KUBE adm policy add-scc-to-user nonroot-v2 -z "$(proxy_sa)" -n "$GW_NS" >/dev/null
    $KUBE rollout restart deploy -n "$GW_NS" -l "$GW_LABEL" >/dev/null
    ok "granted nonroot-v2 to $(proxy_sa)"
  fi
  $KUBE rollout status deploy -n "$GW_NS" -l "$GW_LABEL" --timeout=240s >/dev/null
  $KUBE apply -n "$NS" -f ../_shared/client.yaml -f ../_shared/echo-app.yaml >/dev/null
  $KUBE apply -f manifests/40-httproute.yaml >/dev/null
  wait_ready echo
  $KUBE wait gateway/eg -n "$NS" --for=condition=Programmed --timeout=120s >/dev/null \
    || { bad "Gateway never Programmed - see 'Troubleshooting' in the README"; exit 1; }
  if has_routes && ! $KUBE get route gwapi-demo -n "$GW_NS" >/dev/null 2>&1; then
    $KUBE expose -n "$GW_NS" "$($KUBE get svc -n "$GW_NS" -l "$GW_LABEL" -o name)" \
      --name=gwapi-demo --hostname="$ROUTE_HOST" >/dev/null
  fi
  ok "Gateway eg programmed at $($KUBE get gateway eg -n "$NS" -o jsonpath='{.status.addresses[0].value}')"
}

verify() {
  say "1. the Gateway API objects"
  assert "GatewayClass accepted" "True" \
    "$($KUBE get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')"
  assert "Gateway programmed" "True" \
    "$($KUBE get gateway eg -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')"
  assert "HTTPRoute accepted by the Gateway" "True" \
    "$($KUBE get httproute echo -n "$NS" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')"
  assert "HTTPRoute backends resolved" "True" \
    "$($KUBE get httproute echo -n "$NS" -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}')"
  ADDR=$($KUBE get gateway eg -n "$NS" -o jsonpath='{.status.addresses[0].value}')
  [ -n "$ADDR" ] || { bad "no address assigned - is the IPAddressPool autoAssign: false?"; summary; exit 1; }

  say "2. traffic through the Gateway's address, $ADDR"
  client_ready
  BODY=$(incluster_curl "http://$ADDR/hello")
  assert_contains "the backend answered"      '"served_by"'   "$BODY"
  assert_contains "the path reached it"       '"/hello"'      "$BODY"
  # The proof a proxy was in the path: the app never sets these.
  assert_contains "Envoy is in the path"      'x-envoy'       "$BODY"
  assert_contains "a request id was injected" 'x-request-id'  "$BODY"

  say "3. the Envoy config the controller generated"
  assert_contains "the backend cluster load-balances with least_request" \
    "envoy.load_balancing_policies.least_request" "$(./admin.sh 'config_dump?resource=dynamic_active_clusters')"
  # Envoy holds the pods themselves (EDS), not the Service's virtual IP.
  WANT=$($KUBE get pods -n "$NS" -l app=echo -o jsonpath='{range .items[*]}{.status.podIP}:8080{"\n"}{end}' | sort | tr '\n' ' ')
  GOT=$(./admin.sh clusters | awk -F'::' '$1 ~ /^httproute\/'"$NS"'\/echo\// && $3 == "health_flags" { print $2 }' | sort | tr '\n' ' ')
  assert "its endpoints are the echo pods" "$WANT" "$GOT"

  if has_routes; then
    say "4. from this machine, through the OpenShift Route"
    assert_contains "http://$ROUTE_HOST/ reaches the backend" '"served_by"' \
      "$(curl -s --max-time 10 "http://$ROUTE_HOST/")"
  fi
  summary
}

clean() {
  # The grant names the proxy's ServiceAccount, which goes with the Gateway -
  # remove it first, while the Deployment still names the account, and before
  # anything below that could wait.
  SA=$(proxy_sa)
  if [ -n "$SA" ] && has_sccs; then
    $KUBE adm policy remove-scc-from-user nonroot-v2 -z "$SA" -n "$GW_NS" >/dev/null 2>&1
  fi
  $KUBE delete route gwapi-demo -n "$GW_NS" --ignore-not-found >/dev/null 2>&1
  $KUBE delete -f manifests/40-httproute.yaml --ignore-not-found >/dev/null 2>&1
  # 30-gateway.yaml holds the namespace too: deleting it removes echo and client.
  $KUBE delete -f manifests/30-gateway.yaml --ignore-not-found --wait=false >/dev/null 2>&1
  # GatewayClass eg and its EnvoyProxy are shared: later modules create
  # Gateways of this class too. Deleting them under another Gateway takes its
  # EnvoyProxy at once, and Envoy Gateway's finalizer on a class that still has
  # Gateways would hold this delete - and this script - until they are gone.
  if ! others=$($KUBE get gateway -A -o jsonpath='{.items[?(@.spec.gatewayClassName=="eg")].metadata.name}' 2>/dev/null); then
    bad "could not list Gateways - GatewayClass eg and its EnvoyProxy left in place"
  elif [ -n "$others" ]; then
    ok "removed; GatewayClass eg is still used by another Gateway, so it stays"
  else
    $KUBE delete -f manifests/10-gatewayclass.yaml -f manifests/20-envoyproxy.yaml --ignore-not-found >/dev/null 2>&1
    ok "removed (the Envoy Gateway install itself is left alone - see setup/)"
  fi
}

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
