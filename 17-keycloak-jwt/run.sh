#!/usr/bin/env bash
# Module 17 — Keycloak tokens at the Gateway.  ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=envoy-17
. ../_shared/lib.sh
. ../_shared/gateway.sh

# Module 16's lab must be up: this module checks the tokens that Keycloak issues.
need_keycloak() {
  [ "$($KUBE get keycloak keycloak -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] \
    && [ "$($KUBE get keycloakrealmimport tutorial -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null)" = True ] \
    || { bad "module 16's Keycloak lab is not running - ../16-keycloak/run.sh deploy"; exit 1; }
}

deploy() {
  need_keycloak
  say "deploying into $NS"
  $KUBE apply -f ../12-gateway-api/manifests/20-envoyproxy.yaml -f ../12-gateway-api/manifests/10-gatewayclass.yaml >/dev/null
  $KUBE wait gatewayclass/eg --for=condition=Accepted --timeout=60s >/dev/null
  $KUBE apply -f manifests/10-gateway.yaml >/dev/null
  gw_up "$NS" eg
  $KUBE apply -n "$NS" -f ../_shared/client.yaml -f ../_shared/echo-app.yaml -f manifests/20-routes.yaml >/dev/null
  # Keycloak's CA, where the BackendTLSPolicy in the keycloak namespace reads it.
  $KUBE create configmap keycloak-ca -n keycloak --dry-run=client -o yaml \
    --from-literal=ca.crt="$($KUBE get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d)" \
    | $KUBE apply -f - >/dev/null
  $KUBE apply -f manifests/30-trust-keycloak.yaml -f manifests/40-jwt.yaml -f manifests/50-admin-only.yaml >/dev/null
  wait_ready echo
  ok "Gateway eg programmed at $(gw_address "$NS" eg)"
}

# call <token|""> <path> [curl args...] - the response body and, last, " -> <status>".
call() {
  local tok=$1 path=$2; shift 2
  if [ -n "$tok" ]; then incluster_curl -w ' -> %{http_code}' -H "authorization: Bearer $tok" "$@" "http://$ADDR$path"
  else incluster_curl -w ' -> %{http_code}' "$@" "http://$ADDR$path"; fi
}
condition() { $KUBE get "$1" -n "$2" -o jsonpath="{.status.ancestors[0].conditions[?(@.type==\"$3\")].status}"; }

verify() {
  need_keycloak
  client_ready
  $KUBE get pod client -n keycloak >/dev/null 2>&1 || $KUBE apply -n keycloak -f ../_shared/client.yaml >/dev/null
  $KUBE wait -n keycloak pod/client --for=condition=Ready --timeout=120s >/dev/null
  $KUBE get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d \
    | $KUBE exec -i -n keycloak client -- sh -c 'cat > /tmp/ca.crt'
  ADDR=$(gw_address "$NS" eg)
  [ -n "$ADDR" ] || { bad "Gateway eg has no address"; FAILED=$((FAILED+1)); summary; exit 1; }
  # Every token through token.sh: one code path, and no password on an `oc exec`
  # command line - the API server's audit log records those (token.sh, top).
  ALICE=$(./token.sh alice)
  BOB=$(./token.sh bob)

  say "1. the policies"
  assert "BackendTLSPolicy to keycloak-service accepted" "True" "$(condition backendtlspolicy/keycloak-service keycloak Accepted)"
  assert "SecurityPolicy keycloak-jwt accepted"           "True" "$(condition securitypolicy/keycloak-jwt "$NS" Accepted)"
  assert "SecurityPolicy admin-only accepted"             "True" "$(condition securitypolicy/admin-only "$NS" Accepted)"
  assert "...and the Gateway's policy says it is overridden on /admin" "True" \
    "$(condition securitypolicy/keycloak-jwt "$NS" Overridden)"
  assert "the keys came from keycloak-service over TLS" "yes" \
    "$(../_shared/eg-admin.sh "$NS/eg" stats | awk -F': ' '/^cluster\.securitypolicy\/'"$NS"'\/keycloak-jwt\/jwt\/0\.ssl\.handshake:/ { print ($2 > 0) ? "yes" : "no" }')"

  say "2. who gets through /api"
  assert_contains "no token -> 401"                 "Jwt is missing -> 401"   "$(call "" /api)"
  R=$(call "$ALICE" /api)
  assert_contains "alice -> 200"                    " -> 200"                 "$R"
  assert_contains "...and the app is told who"      '"x-user": "alice"'       "$R"
  TAMPERED=$(python3 - "$ALICE" <<'PY'
import base64, json, sys
h, p, s = sys.argv[1].split(".")
c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
c["realm_access"]["roles"].append("admin")
print(".".join([h, base64.urlsafe_b64encode(json.dumps(c).encode()).decode().rstrip("="), s]))
PY
)
  assert_contains "a token edited to add a role -> 401" "Jwt verification fails -> 401" "$(call "$TAMPERED" /api)"
  OTHER_AUD=$(./token.sh alice-admin-cli)
  assert_contains "a token not meant for shop-api -> 403" "Audiences in Jwt are not allowed -> 403" "$(call "$OTHER_AUD" /api)"
  MASTER=$(./token.sh master-admin)
  assert_contains "a token from another realm -> 401" "Jwt issuer is not configured -> 401" "$(call "$MASTER" /api)"
  SVC=$(./token.sh orders-service)
  assert_contains "orders-service -> 200, as itself" '"x-user": "service-account-orders-service"' "$(call "$SVC" /api)"

  say "3. who gets through /admin (realm role admin)"
  assert_contains "alice (reader) -> 403" "RBAC: access denied -> 403" "$(call "$ALICE" /admin)"
  # A caller's own x-client must not reach the app: the route's policy replaces
  # the Gateway's, so it must set (and so clear) every header the Gateway's sets.
  R=$(call "$BOB" /admin -H 'x-client: forged-client')
  assert_contains "bob (admin) -> 200"    " -> 200"                    "$R"
  assert_contains "...and the app gets the token's client, not the caller's x-client" '"x-client": "shop-cli"' "$R"
  summary
}

clean() {
  gw_down "$NS" eg
  $KUBE delete -f manifests/10-gateway.yaml --ignore-not-found --wait=false >/dev/null 2>&1
  # What this module added next to Keycloak - not the lab itself.
  $KUBE delete -f manifests/30-trust-keycloak.yaml --ignore-not-found >/dev/null 2>&1
  $KUBE delete configmap keycloak-ca -n keycloak --ignore-not-found >/dev/null 2>&1
  ok "namespace $NS deleting; module 16's Keycloak lab is left running"
}

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
