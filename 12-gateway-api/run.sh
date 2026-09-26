#!/usr/bin/env bash
# Module 12 — the Gateway API.  ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=gwapi-demo
. ../_shared/lib.sh

deploy() {
  say "deploying"
  $KUBE apply -f manifests/20-envoyproxy.yaml -f manifests/10-gatewayclass.yaml >/dev/null
  $KUBE apply -f manifests/30-gateway.yaml >/dev/null
  $KUBE apply -n "$NS" -f ../_shared/echo-app.yaml >/dev/null
  $KUBE apply -f manifests/40-httproute.yaml >/dev/null
  wait_ready echo
  # Each Gateway gets its own ServiceAccount, so the SCC grant is per-Gateway.
  # Skipped silently off OpenShift, where there are no SCCs to grant.
  if $KUBE api-resources --api-group=security.openshift.io 2>/dev/null | grep -q securitycontextconstraints; then
    SA=$($KUBE get deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg \
          -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}' 2>/dev/null)
    [ -n "$SA" ] && oc adm policy add-scc-to-user nonroot-v2 -z "$SA" -n envoy-gateway-system >/dev/null 2>&1 \
      && ok "granted nonroot-v2 to $SA"
  fi
  say "gateway address"
  $KUBE get gateway eg -n "$NS" -o jsonpath='  {.status.addresses[0].value}{"\n"}'
}

verify() {
  say "checking the Gateway API objects"
  assert "GatewayClass accepted" "True" \
    "$($KUBE get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')"
  assert "Gateway programmed" "True" \
    "$($KUBE get gateway eg -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')"
  assert "HTTPRoute refs resolved" "True" \
    "$($KUBE get httproute echo -n "$NS" -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}')"

  ADDR=$($KUBE get gateway eg -n "$NS" -o jsonpath='{.status.addresses[0].value}')
  [ -z "$ADDR" ] && { bad "no address assigned — is the IPAddressPool autoAssign:false?"; return 1; }
  ok "address $ADDR"

  say "checking traffic actually flows"
  client_ready
  BODY=$(incluster_curl "http://$ADDR/hello")
  assert_contains "backend answered"        '"served_by"'   "$BODY"
  assert_contains "path reached the backend" '"/hello"'     "$BODY"
  # The proof a proxy was in the path: the app never sets these.
  assert_contains "Envoy is in the path"     'x-envoy'      "$BODY"
  assert_contains "request id injected"      'x-request-id' "$BODY"
  summary
}

clean() {
  $KUBE delete -f manifests/40-httproute.yaml --ignore-not-found >/dev/null 2>&1
  $KUBE delete -n "$NS" -f ../_shared/echo-app.yaml --ignore-not-found >/dev/null 2>&1
  $KUBE delete -f manifests/30-gateway.yaml --ignore-not-found >/dev/null 2>&1
  $KUBE delete -f manifests/10-gatewayclass.yaml -f manifests/20-envoyproxy.yaml --ignore-not-found >/dev/null 2>&1
  # verify's incluster_curl starts _shared/client.yaml here; this clean is not a
  # namespace delete, so remove the pod by name.
  $KUBE delete pod client -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
  ok "removed (the Envoy Gateway install itself is left alone — see setup/)"
}

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //' ; exit 2 ;;
esac
