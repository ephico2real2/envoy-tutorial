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
# corp_state - the Done condition of module 18's realm import: "True" when realm
# corp - the second issuer the policies name - has been imported.
corp_state() {
  $KUBE get keycloakrealmimport corp -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null
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
  # Not fatal: tutorial's tokens work without corp. Steps 8 to 10 need it.
  [ "$(corp_state)" = True ] \
    || echo "  note: realm corp is not imported - steps 8 to 10 need module 18 (../18-keycloak-ldap/run.sh deploy)"
}

# call <token|""> <path> [curl args...] - the response body and, last, " -> <status>".
# A token goes to request.sh on standard input, never as an argument: the API server's
# audit log records `oc exec` arguments (request.sh, top). A shell function's arguments
# are not a process's, so passing it to call() is fine.
call() {
  local tok=$1 path=$2; shift 2
  if [ -n "$tok" ]; then printf '%s\n' "$tok" | ADDR="$ADDR" ./request.sh "$path" --max-time 10 -w ' -> %{http_code}' "$@" 2>/dev/null
  else incluster_curl -w ' -> %{http_code}' "$@" "http://$ADDR$path"; fi
}
# claims - the access token on stdin, as "name value" lines: preferred_username, and
# roles (the realm roles, sorted). On stdin, never in python's argv.
claims() {
  python3 -c '
import base64, json, sys
p = sys.stdin.read().strip().split(".")[1]
c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
print("preferred_username", c.get("preferred_username"))
print("roles", " ".join(sorted(c.get("realm_access", {}).get("roles", []))))' 2>/dev/null
}
claim() { sed -n "s/^$1 //p" <<<"$2"; }
# ready_client <namespace> <how to create it> - verify reads the lab, it does not build it:
# a missing client pod is a failure that names the step creating it (an earlier
# version applied one silently).
ready_client() {
  [ "$($KUBE get pod client -n "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] \
    || { bad "pod/client in $1 is not Ready - $2"; exit 1; }
}
# gate_refusal <since> <user> - why Keycloak refused <user>'s last login in corp since
# <since> (RFC 3339), from its own
# log: invalid_grant alone is also the answer to a wrong password. Retries briefly,
# because the event line is written as the request completes.
gate_refusal() {
  local since=$1 user=$2 why=
  for _ in 1 2 3 4 5; do
    why=$($KUBE logs keycloak-0 -n keycloak --since-time="$since" 2>/dev/null \
      | grep LOGIN_ERROR | grep 'realmName="corp"' | grep "username=\"$user\"" | tail -n 1 \
      | grep -o 'error="[^"]*"')
    [ -n "$why" ] && break
    sleep 1
  done
  echo "${why:-no LOGIN_ERROR for $user in the log of keycloak-0 since $since}"
}
condition() { $KUBE get "$1" -n "$2" -o jsonpath="{.status.ancestors[0].conditions[?(@.type==\"$3\")].status}"; }
# requirements - from the running Envoy, one line per route: its path, how its JWT
# requirement combines providers, and the realms of those providers' issuers, e.g.
# "/api requires_any corp tutorial". The listener holds the requirements and the
# providers; each route names the requirement it uses. Empty if Envoy cannot be asked.
requirements() {
  python3 - "$NS/eg" <<'PY' 2>/dev/null
import json, subprocess, sys
def dump(resource):
    out = subprocess.run(["../_shared/eg-admin.sh", sys.argv[1], "config_dump?resource=" + resource],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out)["configs"]
reqs, providers = {}, {}
for l in dump("dynamic_listeners"):
    listener = l["active_state"]["listener"]
    for fc in [listener.get("default_filter_chain")] + listener.get("filter_chains", []):
        for f in (fc or {}).get("filters", []):
            for h in f["typed_config"].get("http_filters", []):
                if h["name"].startswith("envoy.filters.http.jwt_authn"):
                    reqs.update(h["typed_config"].get("requirement_map", {}))
                    providers.update(h["typed_config"]["providers"])
for c in dump("dynamic_route_configs"):
    for vh in c["route_config"]["virtual_hosts"]:
        for r in vh["routes"]:
            name = r.get("typed_per_filter_config", {}).get("envoy.filters.http.jwt_authn", {}).get("requirement_name")
            if name:
                # One provider: {"provider_name": p}. Several: {"requires_any": {"requirements": [...]}}.
                (kind, body), = reqs[name].items()
                names = [body] if kind == "provider_name" else [x["provider_name"] for x in body["requirements"]]
                realms = sorted(providers[p]["issuer"].rsplit("/", 1)[1] for p in names)
                print(r["match"].get("path_separated_prefix", r["match"]), kind, " ".join(realms))
PY
}

verify() {
  need_keycloak
  ready_client "$NS" "./run.sh deploy"
  ready_client keycloak "module 16, step 6: oc apply -n keycloak -f ../_shared/client.yaml"
  # Checked above; stops incluster_curl from creating the pod (lib.sh, client_ensure).
  CLIENT_READY=1
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
  STATS=$(../_shared/eg-admin.sh "$NS/eg" stats)
  assert "the keys came from keycloak-service over TLS" "yes" \
    "$(awk -F': ' '/^cluster\.securitypolicy\/'"$NS"'\/keycloak-jwt\/jwt\/0\.ssl\.handshake:/ { print ($2 > 0) ? "yes" : "no" }' <<<"$STATS")"
  # Provider 1 of keycloak-jwt is corp: Envoy Gateway numbers the JWKS clusters
  # in the policy's provider order.
  assert "...and corp's keys too" "yes" \
    "$(awk -F': ' '/^cluster\.securitypolicy\/'"$NS"'\/keycloak-jwt\/jwt\/1\.ssl\.handshake:/ { print ($2 > 0) ? "yes" : "no" }' <<<"$STATS")"
  REQS=$(requirements)
  assert "/api accepts a token from either realm (requires_any)"   "/api requires_any corp tutorial"   "$(grep '^/api ' <<<"$REQS")"
  assert "/admin accepts a token from either realm (requires_any)" "/admin requires_any corp tutorial" "$(grep '^/admin ' <<<"$REQS")"

  say "2. who gets through /api"
  assert_contains "no token -> 401"                 "Jwt is missing -> 401"   "$(call "" /api)"
  R=$(call "$ALICE" /api)
  assert_contains "alice -> 200"                    " -> 200"                 "$R"
  assert_contains "...and the app is told who"      '"x-user": "alice"'       "$R"
  TAMPERED=$(printf '%s' "$ALICE" | python3 -c '
import base64, json, sys
h, p, s = sys.stdin.read().strip().split(".")
c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
c["realm_access"]["roles"].append("admin")
print(".".join([h, base64.urlsafe_b64encode(json.dumps(c).encode()).decode().rstrip("="), s]))')
  assert_contains "a token edited to add a role -> 401" "Jwt verification fails -> 401" "$(call "$TAMPERED" /api)"
  OTHER_AUD=$(./token.sh alice-admin-cli)
  assert_contains "a token not meant for shop-api -> 403" "Audiences in Jwt are not allowed -> 403" "$(call "$OTHER_AUD" /api)"
  MASTER=$(./token.sh master-admin)
  assert_contains "a token from another realm -> 401" "Jwt issuer is not configured -> 401" "$(call "$MASTER" /api)"
  SVC=$(./token.sh orders-service)
  R=$(call "$SVC" /api)
  assert_contains "orders-service -> 200"           " -> 200"                 "$R"
  assert_contains "...as itself" '"x-user": "service-account-orders-service"' "$R"
  R=$(call "$BOB" /api)
  assert_contains "bob -> 200"                      " -> 200"                 "$R"
  assert_contains "...as bob"                       '"x-user": "bob"'         "$R"

  say "3. who gets through /admin (realm role admin)"
  assert_contains "alice (reader) -> 403" "RBAC: access denied -> 403" "$(call "$ALICE" /admin)"
  # A caller's own x-client must not reach the app: the route's policy replaces
  # the Gateway's, so it must set (and so clear) every header the Gateway's sets.
  R=$(call "$BOB" /admin -H 'x-client: forged-client')
  assert_contains "bob (admin) -> 200"    " -> 200"                    "$R"
  assert_contains "...and the app gets the token's client, not the caller's x-client" '"x-client": "shop-cli"' "$R"

  say "4. realm corp: people from LDAP (module 18), admin from an LDAP group"
  assert "realm corp imported (module 18)" "True" "$(corp_state)"
  SHOP_ALICE=$(./token.sh shop.alice)
  SHOP_BOB=$(./token.sh shop.bob)
  R=$(call "$SHOP_ALICE" /api)
  assert_contains "shop.alice (gate member) -> /api 200" " -> 200"                   "$R"
  assert_contains "...and the app is told her LDAP uid" '"x-user": "shop.alice"'     "$R"
  assert_contains "shop.bob -> /api 200"                " -> 200"                    "$(call "$SHOP_BOB" /api)"
  assert_contains "shop.alice (not in keycloak-admin) -> /admin 403" "RBAC: access denied -> 403" "$(call "$SHOP_ALICE" /admin)"
  R=$(call "$SHOP_BOB" /admin -H 'x-client: forged-client')
  assert_contains "shop.bob (in keycloak-admin) -> /admin 200" " -> 200"             "$R"
  assert_contains "...as himself"                       '"x-user": "shop.bob"'       "$R"
  assert_contains "...and the app gets the token's client, not the caller's x-client" '"x-client": "shop-cli"' "$R"
  # ns-developer is a gate group with no Keycloak role (#8): jeff gets only what corp
  # gives every user, and so /api but not /admin.
  JEFF=$(./token.sh jeff)
  assert "jeff (ns-developer): corp's default roles only" "default-roles-corp offline_access uma_authorization" \
    "$(claim roles "$(printf '%s' "$JEFF" | claims)")"
  assert_contains "jeff -> /api 200"                     " -> 200"                    "$(call "$JEFF" /api)"
  assert_contains "jeff -> /admin 403"                   "RBAC: access denied -> 403" "$(call "$JEFF" /admin)"
  # Refused by Keycloak, before the Gateway: the gate is corp's user search. The
  # caller hears invalid_grant for a wrong password too, so Keycloak's log decides.
  SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  assert_contains "bob.wilson (outside the login gate): no corp token" "no token: {'error': 'invalid_grant'" \
    "$(./token.sh bob.wilson 2>&1)"
  assert "...because Keycloak does not find him (not a wrong password)" 'error="user_not_found"' \
    "$(gate_refusal "$SINCE" bob.wilson)"
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
