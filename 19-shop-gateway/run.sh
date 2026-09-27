#!/usr/bin/env bash
# Module 19 — the shop behind the Gateway: sign-in, JWT, permissions.  ./run.sh deploy | verify | clean | pause | resume
cd "$(dirname "$0")"
NS=envoy-19
. ../_shared/lib.sh
. ../_shared/gateway.sh
. ../_shared/argocd.sh

APP=19-shop-gateway
CORP=https://keycloak.apps-crc.testing/realms/corp
TOKEN=../17-keycloak-jwt/token.sh
KC_ADMIN=../18-keycloak-ldap/admin.sh
# Where a browser on the laptop reaches the Gateway, and so what realm corp sends it
# back to (the client's redirect URI, the policy's redirectURL).
LOCAL=127.0.0.1:19080
# The shop and what walls it in - applied before any route leads to it.
SHOP="20-shop-db-secret 21-shop-database 22-shop-inventory-src 23-shop-inventory 24-shop-envoy-config
      25-shop-envoy-proto 26-shop-envoy 27-shop-kiosk-src 28-shop-kiosk 30-network-policy"

# kiosk_client - realm corp's client shop-kiosk as "<redirect URIs> <PKCE method>", or
# nothing when there is none.
kiosk_client() {
  $KC_ADMIN GET '/admin/realms/corp/clients?clientId=shop-kiosk' 2>/dev/null | python3 -c '
import json, sys
for c in json.load(sys.stdin):
    print(",".join(c["redirectUris"]), c["attributes"].get("pkce.code.challenge.method", "-"))' 2>/dev/null
}
# What this module builds on: module 16's Keycloak, module 18's realm corp with the
# kiosk's client (README step 2), and module 16's BackendTLSPolicy to keycloak-service.
need_lab() {
  [ "$($KUBE get keycloak keycloak -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] \
    || { bad "module 16's Keycloak is not running - ../16-keycloak/run.sh deploy"; exit 1; }
  [ "$($KUBE get keycloakrealmimport corp -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null)" = True ] \
    || { bad "realm corp is not imported - ../18-keycloak-ldap/run.sh deploy"; exit 1; }
  [ -n "$(kiosk_client)" ] \
    || { bad "realm corp has no client shop-kiosk - README step 2 re-imports corp with it"; exit 1; }
  $KUBE get backendtlspolicy keycloak-service -n keycloak >/dev/null 2>&1 \
    || { bad "no BackendTLSPolicy keycloak/keycloak-service - ../16-keycloak/run.sh deploy makes it"; exit 1; }
}

# forward - on CRC, make the laptop's port 19080 reach the Gateway's MetalLB address,
# through CRC's network proxy (README step 7; ../_shared/crc-forward.sh). "yes" when
# the forward is there, "not CRC" when there is no CRC to ask; anything else fails.
forward() {
  local addr out rc=0
  addr=$(gw_address "$NS" eg)
  [ -n "$addr" ] || { bad "Gateway eg has no address to forward to"; return 1; }
  out=$(../_shared/crc-forward.sh ensure "$LOCAL" "$addr:80" 2>&1) || rc=$?
  case $rc in
    0) ok "$out" ;;
    3) echo "  note: not CRC - a browser must reach $addr itself, and realm corp sends it back to http://localhost:19080 (README step 7)" ;;
    *) bad "$out"; return 1 ;;
  esac
}

# kiosk_secret_copy - Secret shop-kiosk-oidc in envoy-19, the Gateway's copy of module
# 18's shop-kiosk-client (key client-secret, which Envoy Gateway reads). The value goes
# from one Secret to the other through a pipe, never an argument; an unchanged copy is
# left as it is ("unchanged").
kiosk_secret_copy() {
  local v
  v=$($KUBE get secret shop-kiosk-client -n keycloak -o jsonpath='{.data.client-secret}' 2>/dev/null)
  [ -n "$v" ] || { bad "no Secret shop-kiosk-client in keycloak - ../18-keycloak-ldap/run.sh deploy makes it"; return 1; }
  printf '%s' "$v" | base64 -d \
    | $KUBE create secret generic shop-kiosk-oidc -n "$NS" --from-file=client-secret=/dev/stdin --dry-run=client -o yaml \
    | $KUBE apply -f - >/dev/null || { bad "Secret shop-kiosk-oidc could not be written"; return 1; }
}

deploy() {
  need_lab
  say "deploying into $NS"
  $KUBE apply -f ../12-gateway-api/manifests/20-envoyproxy.yaml -f ../12-gateway-api/manifests/10-gatewayclass.yaml >/dev/null \
    || { bad "module 12's GatewayClass eg and EnvoyProxy could not be applied"; exit 1; }
  $KUBE wait gatewayclass/eg --for=condition=Accepted --timeout=60s >/dev/null \
    || { bad "GatewayClass eg was not accepted - is Envoy Gateway running? (module 12)"; exit 1; }
  ns_settle "$NS"
  $KUBE apply -f manifests/10-gateway.yaml >/dev/null || { bad "could not create the Gateway in $NS"; exit 1; }
  gw_up "$NS" eg
  # 1. The shop and its NetworkPolicies. No route leads to it yet.
  local f
  for f in $SHOP; do
    $KUBE apply -f "manifests/$f.yaml" >/dev/null || { bad "manifests/$f.yaml could not be applied"; exit 1; }
  done
  $KUBE apply -n "$NS" -f ../_shared/client.yaml -f ../_shared/echo-app.yaml >/dev/null \
    || { bad "the client pod and the echo app could not be applied"; exit 1; }
  # The inventory installs its Python packages at start (23-shop-inventory.yaml).
  wait_ready inventory-db 300s; wait_ready inventory 300s; wait_ready envoy; wait_ready kiosk; wait_ready echo
  client_ready
  # 2. The sign-in, accepted, before anything can reach the shop through the Gateway.
  kiosk_secret_copy || exit 1
  $KUBE apply -f manifests/50-trust-keycloak.yaml -f manifests/70-sign-in.yaml >/dev/null \
    || { bad "the ReferenceGrant and SecurityPolicy sign-in could not be applied - no route published"; exit 1; }
  $KUBE wait securitypolicy/sign-in -n "$NS" --for=jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}'=True \
    --timeout=60s >/dev/null \
    || { bad "SecurityPolicy sign-in not accepted - no route published; oc get securitypolicy sign-in -n $NS -o yaml"; exit 1; }
  # 3. Only now the route.
  $KUBE apply -f manifests/40-route.yaml >/dev/null || { bad "HTTPRoute shop could not be applied"; exit 1; }
  $KUBE wait httproute/shop -n "$NS" --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
    --timeout=60s >/dev/null || { bad "HTTPRoute shop not accepted - oc get httproute shop -n $NS -o yaml"; exit 1; }
  wait_keycloak_tls "$NS"
  # The first calls can fail while the shop's Envoy finds the inventory (README step
  # 6): wait, a minute at most, until a signed-in call gets the shop's answer.
  local tok code=
  tok=$($TOKEN shop.alice) || { bad "no token for shop.alice from realm corp"; exit 1; }
  for _ in $(seq 1 30); do
    code=$(printf '%s\n' "$tok" | ADDR=$(gw_address "$NS" eg) ./request.sh GET /v1/items -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$code" = 200 ] && break
    sleep 2
  done
  [ "$code" = 200 ] || { bad "the shop never answered through the Gateway (last: ${code:-none})"; exit 1; }
  forward || exit 1
  ok "the shop is up behind Gateway eg at $(gw_address "$NS" eg); in a browser: http://localhost:19080"
  app_resume "$APP"
}

# claims - the JWT on stdin, as "name value" lines: iss, azp, preferred_username, aud
# and roles (sorted, space-separated). On stdin, never in python's argv.
claims() {
  python3 -c '
import base64, json, sys
t = sys.stdin.read().strip()
if t.count(".") != 2:
    print("error", t[:80]); sys.exit()
p = t.split(".")[1]
c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
for k in ("iss", "azp", "preferred_username", "exp"):
    print(k, c.get(k))
aud = c.get("aud"); print("aud", " ".join(sorted(aud if isinstance(aud, list) else [aud])))
print("roles", " ".join(sorted(c.get("realm_access", {}).get("roles", []))))'
}
claim() { sed -n "s/^$1 //p" <<<"$2"; }
has() { case " $2 " in (*" $1 "*) echo yes ;; (*) echo no ;; esac; }
# forwarded - the bearer token the Gateway sent on to the app, from the echo at /whoami
# (the response body on stdin).
forwarded() { python3 -c 'import json, sys; print(json.load(sys.stdin)["headers"].get("authorization", "").removeprefix("Bearer "))' 2>/dev/null; }

# as_browser <user> <METHOD> <path> [curl args...] - status of a call with the user's session.
as_browser() { ./browser.sh "$@" -o /dev/null -w '%{http_code}'; }
# with_token <token> <METHOD> <path> [curl args...] - body, then " -> <status>". The
# token goes to request.sh on stdin (a shell function's arguments are no process's).
with_token() { local t=$1; shift; printf '%s\n' "$t" | ./request.sh "$@" -w ' -> %{http_code}' 2>/dev/null; }
JSON=(-H 'content-type: application/json')

# item <create|delete> <sku> - a disposable item, made and removed by shop.bob (admin)
# with a fresh bearer token. The checks reserve on these, never on the shop's own items.
item() {
  local body=
  [ "$1" = create ] && body="{\"sku\":\"$2\",\"name\":\"verify\",\"onHand\":5,\"warehouse\":\"LEEDS\"}"
  case "$1" in
    create) with_token "$($TOKEN shop.bob)" POST /v1/items "${JSON[@]}" -d "$body" -o /dev/null ;;
    delete) with_token "$($TOKEN shop.bob)" DELETE "/v1/items/$2" -o /dev/null ;;
  esac
}
# reserved - "ok <ok> reserved <n>" from a ReserveStock answer on stdin: the shop says
# whether it reserved (ok) and how many are now reserved - a 200 alone is not a reservation.
reserved() {
  python3 -c 'import json, sys; r = json.load(sys.stdin); print("ok", str(r.get("ok")).lower(), "reserved", r.get("reserved"))' 2>/dev/null \
    || echo "not a ReserveStock answer"
}
# tcp_from_client <host:port> - "reachable" or "blocked": can the client pod open a TCP
# connection there at all (curl's telnet://, 3 s)? For ports that do not speak HTTP.
tcp_from_client() {
  incluster_sh "curl -sv --connect-timeout 3 -m 4 telnet://$1 </dev/null 2>&1 | grep -q 'Connected to' && echo reachable || echo blocked"
}

# gate_refusal <since> <user> - why Keycloak refused <user>'s last sign-in to corp, from
# its own log (the login page says the same for a wrong password).
gate_refusal() {
  local since=$1 user=$2 why=
  for _ in 1 2 3 4 5; do
    why=$($KUBE logs keycloak-0 -n keycloak --since-time="$since" 2>/dev/null \
      | grep LOGIN_ERROR | grep 'realmName="corp"' | grep 'clientId="shop-kiosk"' | grep "username=\"$user\"" \
      | tail -n 1 | grep -o 'error="[^"]*"')
    [ -n "$why" ] && break
    sleep 1
  done
  echo "${why:-no LOGIN_ERROR for $user in keycloak-0 since $since}"
}
# exec_audit <since> - "<n> <m>": the pod exec requests in envoy-19 and keycloak that the
# API server's audit log recorded since <since>, and how many of them carry one of the
# secrets read on stdin, one per line. An exec's arguments are in its request URL.
exec_audit() {
  python3 -c '
import json, sys
since, secrets = sys.argv[1], [s for s in sys.stdin.read().split() if s]
n = m = 0
for line in open(3, errors="replace"):
    try:
        e = json.loads(line[line.index("{"):])
    except ValueError:
        continue
    if e.get("objectRef", {}).get("subresource") != "exec" or e.get("stage") != "ResponseComplete":
        continue
    if e["objectRef"].get("namespace") not in ("envoy-19", "keycloak") or e["requestReceivedTimestamp"] < since:
        continue
    n += 1
    m += any(s in e["requestURI"] for s in secrets)
print(n, m)' "$1" 3< <($KUBE adm node-logs --role=master --path=kube-apiserver/audit.log 2>/dev/null)
}

verify() {
  need_lab
  client_ready
  ADDR=$(gw_address "$NS" eg); export ADDR
  [ -n "$ADDR" ] || { bad "Gateway eg has no address"; FAILED=$((FAILED+1)); summary; exit 1; }
  local since; since=$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)
  # A token taken now is expired by the end (section 6): corp's tokens live 300 s.
  local OLD; OLD=$($TOKEN shop.alice)

  say "1. the objects, and the filters Envoy Gateway made of them"
  assert "Gateway programmed" "True" \
    "$($KUBE get gateway eg -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')"
  assert "HTTPRoute shop accepted" "True" \
    "$($KUBE get httproute shop -n "$NS" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')"
  assert "SecurityPolicy sign-in accepted" "True" \
    "$($KUBE get securitypolicy sign-in -n "$NS" -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}')"
  assert "the Gateway's client secret is module 18's (Secret shop-kiosk-oidc = keycloak/shop-kiosk-client)" "same" \
    "$([ -n "$($KUBE get secret shop-kiosk-oidc -n "$NS" -o jsonpath='{.data.client-secret}' 2>/dev/null)" ] \
       && [ "$($KUBE get secret shop-kiosk-oidc -n "$NS" -o jsonpath='{.data.client-secret}')" = "$($KUBE get secret shop-kiosk-client -n keycloak -o jsonpath='{.data.client-secret}')" ] \
       && echo same || echo differ)"
  assert "module 16's BackendTLSPolicy to keycloak-service accepts this Gateway's SecurityPolicy" "yes" "$(keycloak_tls "$NS")"
  assert "realm corp's client shop-kiosk: its redirect URI, PKCE S256" \
    "http://localhost:19080/oauth2/callback S256" "$(kiosk_client)"
  assert "the Gateway's filter chain: oauth2, jwt_authn, rbac, router" \
    "envoy.filters.http.oauth2 envoy.filters.http.jwt_authn envoy.filters.http.rbac envoy.filters.http.router" \
    "$(./dump-filters.sh 2>/dev/null | sed -n 's/^  - name: //p' | paste -sd' ' -)"

  say "2. a browser with no session is sent to realm corp's login page"
  forward || FAILED=$((FAILED+1))
  if ../_shared/crc-forward.sh list 2>/dev/null | grep -q "^$LOCAL -> $ADDR:80$"; then
    assert_contains "from this laptop, http://localhost:19080/ -> 302 to corp's login page" "302 $CORP/protocol/openid-connect/auth?" \
      "$(curl -s -m 10 -o /dev/null -w '%{http_code} %{redirect_url}' http://localhost:19080/)"
  fi
  local R; R=$(incluster_curl -o /dev/null -w '%{http_code} %{redirect_url}' --connect-to "localhost:19080:$ADDR:80" http://localhost:19080/)
  assert_contains "GET / -> 302 to corp's authorization endpoint" "302 $CORP/protocol/openid-connect/auth?" "$R"
  assert_contains "...as client shop-kiosk"            "client_id=shop-kiosk"                  "$R"
  assert_contains "...with a PKCE S256 challenge"      "code_challenge_method=S256"            "$R"
  assert_contains "...and the laptop's address to come back to" \
    "redirect_uri=http%3A%2F%2Flocalhost%3A19080%2Foauth2%2Fcallback" "$R"

  say "3. shop.alice signs in: she may list and reserve, not create, delete or reset"
  assert "shop.alice signs in on corp's login page" "0" "$(./browser.sh sign-in shop.alice >/dev/null 2>&1; echo $?)"
  local A; A=$(./browser.sh shop.alice GET /whoami | forwarded | claims)
  assert "her JWT, as the Gateway sent it on: issued by corp"  "$CORP"       "$(claim iss "$A")"
  assert "...to the kiosk's client"                            "shop-kiosk"  "$(claim azp "$A")"
  assert "...for the shop's API (aud shop-api)"                "yes"         "$(has shop-api "$(claim aud "$A")")"
  assert "...as shop.alice, without admin"                     "shop.alice no" "$(claim preferred_username "$A") $(has admin "$(claim roles "$A")")"
  assert "GET /v1/items -> 200"                      "200" "$(as_browser shop.alice GET /v1/items)"
  assert "GET /v1/warehouses -> 200"                 "200" "$(as_browser shop.alice GET /v1/warehouses)"
  local SKU_B; SKU_B="VERIFY-19-B-$(date +%s)"
  assert_contains "(shop.bob makes a disposable item, $SKU_B)" " -> 200" "$(item create "$SKU_B")"
  assert "POST /v1/items/$SKU_B:reserve -> reserved (ok true, 1 reserved)" "ok true reserved 1" \
    "$(./browser.sh shop.alice POST "/v1/items/$SKU_B:reserve" "${JSON[@]}" -d '{"quantity":1,"orderId":"VERIFY-19"}' | reserved)"
  assert "POST /v1/items (create) -> 403"            "403" "$(as_browser shop.alice POST /v1/items "${JSON[@]}" -d '{"sku":"SKU-V19","name":"verify","onHand":1,"warehouse":"LEEDS"}')"
  assert "DELETE /v1/items/$SKU_B -> 403"            "403" "$(as_browser shop.alice DELETE "/v1/items/$SKU_B")"
  assert "POST /v1/items:reset -> 403"               "403" "$(as_browser shop.alice POST /v1/items:reset "${JSON[@]}" -d '{}')"

  say "4. shop.bob signs in: admin, from his LDAP group - he may create and delete"
  assert "shop.bob signs in on corp's login page" "0" "$(./browser.sh sign-in shop.bob >/dev/null 2>&1; echo $?)"
  local B; B=$(./browser.sh shop.bob GET /whoami | forwarded | claims)
  assert "his JWT: issued by corp, for shop-api, with admin" "$CORP yes yes" \
    "$(claim iss "$B") $(has shop-api "$(claim aud "$B")") $(has admin "$(claim roles "$B")")"
  assert "POST /v1/items (create SKU-V19) -> 200"    "200" "$(as_browser shop.bob POST /v1/items "${JSON[@]}" -d '{"sku":"SKU-V19","name":"verify","onHand":1,"warehouse":"LEEDS"}')"
  assert "DELETE /v1/items/SKU-V19 -> 200"           "200" "$(as_browser shop.bob DELETE /v1/items/SKU-V19)"
  assert "POST /v1/items:reset -> 200"               "200" "$(as_browser shop.bob POST /v1/items:reset "${JSON[@]}" -d '{}')"
  assert "DELETE /v1/items/$SKU_B (the disposable item) -> 200" "200" "$(as_browser shop.bob DELETE "/v1/items/$SKU_B")"
  assert "shop.bob signs out: back to corp's logout, then the shop" "2. corp logout -> 302, to http://localhost:19080/" \
    "$(./browser.sh sign-out shop.bob 2>/dev/null | grep '^2\.')"

  say "5. bob.wilson - in the directory, outside the login gate - cannot sign in"
  local S; S=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  assert_contains "the login page refuses him"            "sign-in as bob.wilson refused: 200, Invalid username or password." \
    "$(./browser.sh sign-in bob.wilson 2>&1)"
  assert "...because Keycloak does not find him" 'error="user_not_found"' "$(gate_refusal "$S" bob.wilson)"

  say "6. the command line: a bearer JWT, the same answers"
  local CA CB TUT TAMPERED
  CA=$($TOKEN shop.alice); CB=$($TOKEN shop.bob); TUT=$($TOKEN alice)
  assert_contains "shop.alice: GET /v1/items -> 200"           " -> 200" "$(with_token "$CA" GET /v1/items -o /dev/null)"
  local SKU_C; SKU_C="VERIFY-19-C-$(date +%s)"
  assert_contains "(shop.bob makes a disposable item, $SKU_C)" " -> 200" "$(item create "$SKU_C")"
  assert "shop.alice: reserve -> reserved (ok true, 1 reserved)" "ok true reserved 1" \
    "$(printf '%s\n' "$CA" | ./request.sh POST "/v1/items/$SKU_C:reserve" "${JSON[@]}" -d '{"quantity":1,"orderId":"VERIFY-19"}' 2>/dev/null | reserved)"
  assert_contains "shop.alice: create -> 403 RBAC"             "RBAC: access denied -> 403" "$(with_token "$CA" POST /v1/items "${JSON[@]}" -d '{"sku":"SKU-V19","name":"verify","onHand":1,"warehouse":"LEEDS"}')"
  assert_contains "shop.alice: delete -> 403 RBAC"             "RBAC: access denied -> 403" "$(with_token "$CA" DELETE "/v1/items/$SKU_C")"
  assert_contains "shop.alice: reset -> 403 RBAC"              "RBAC: access denied -> 403" "$(with_token "$CA" POST /v1/items:reset "${JSON[@]}" -d '{}')"
  assert_contains "shop.bob: create -> 200"                    " -> 200" "$(with_token "$CB" POST /v1/items "${JSON[@]}" -d '{"sku":"SKU-V19","name":"verify","onHand":1,"warehouse":"LEEDS"}' -o /dev/null)"
  assert_contains "shop.bob: delete -> 200"                    " -> 200" "$(with_token "$CB" DELETE /v1/items/SKU-V19 -o /dev/null)"
  # Requests shaped to slip past the reserve rule, as shop.alice, sent exactly as
  # written (--path-as-is). Each must stop at the Gateway (README, step 9).
  # code|method|path|a header|the method as sent, when not in capitals. request.sh
  # takes the method in capitals; curl's own -X, given after it, sends another case.
  local code method path header sent_as
  while IFS='|' read -r code method path header sent_as; do
    assert "shop.alice: ${sent_as:-$method} $path${header:+ + $header} -> $code" "$code" \
      "$(printf '%s\n' "$CA" | ./request.sh "$method" "$path" --path-as-is "${JSON[@]}" -d '{"quantity":1,"orderId":"ADV"}' \
           ${header:+-H "$header"} ${sent_as:+-X "$sent_as"} -o /dev/null -w '%{http_code}' 2>/dev/null)"
  done <<ADV
307|POST|/v1/items/${SKU_C}%2Fx:reserve||
403|POST|/v1/items/${SKU_C}%3Fx:reserve||
403|POST|/v1/items/${SKU_C}%3Bx:reserve||
403|POST|/v1/items/${SKU_C}:reserve/||
403|POST|/v1/items/${SKU_C}:reserve?x=1||
403|POST|/v1/items/${SKU_C}:restock||
403|PATCH|/v1/items/${SKU_C}||
403|POST|/v1/items/${SKU_C}|X-HTTP-Method-Override: DELETE|
400|POST|/v1/items/${SKU_C}:reserve||post
ADV
  assert "...and the %2F one's redirect, /v1/items/$SKU_C/x:reserve -> 403" "403" \
    "$(printf '%s\n' "$CA" | ./request.sh POST "/v1/items/$SKU_C/x:reserve" "${JSON[@]}" -d '{"quantity":1}' -o /dev/null -w '%{http_code}' 2>/dev/null)"
  assert "...and $SKU_C holds only the one reservation made above" "ok true reserved 1" \
    "$(printf '%s\n' "$CB" | ./request.sh GET "/v1/items/$SKU_C" 2>/dev/null | python3 -c 'import json, sys; r = json.load(sys.stdin); print("ok true reserved", r.get("reserved"))' 2>/dev/null)"
  assert_contains "(shop.bob removes $SKU_C)" " -> 200" "$(item delete "$SKU_C")"
  assert_contains "shop.bob: reset -> 200"                     " -> 200" "$(with_token "$CB" POST /v1/items:reset "${JSON[@]}" -d '{}' -o /dev/null)"
  TAMPERED=$(printf '%s' "$CA" | python3 -c '
import base64, json, sys
h, p, s = sys.stdin.read().strip().split(".")
c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
c["realm_access"]["roles"].append("admin")
print(".".join([h, base64.urlsafe_b64encode(json.dumps(c).encode()).decode().rstrip("="), s]))')
  assert_contains "shop.alice's JWT edited to add admin -> 401" "Jwt verification fails -> 401" "$(with_token "$TAMPERED" POST /v1/items:reset "${JSON[@]}" -d '{}')"
  assert_contains "a JWT from realm tutorial -> 401"            "Jwt issuer is not configured -> 401" "$(with_token "$TUT" GET /v1/items)"
  local wait_s; wait_s=$(( $(claim exp "$(claims <<<"$OLD")") + 65 - $(date +%s) ))
  if [ "$wait_s" -gt 0 ]; then echo "  (waiting ${wait_s} s for the token taken at the start to expire, plus Envoy's 60 s clock skew and 5 s for the clocks)"; sleep "$wait_s"; fi
  assert_contains "shop.alice's JWT once it has expired -> 401" "Jwt is expired -> 401" "$(with_token "$OLD" GET /v1/items)"

  say "7. the Gateway is the only way in"
  assert "the probe itself: the Gateway's address, port 80, from the client pod" "reachable" "$(tcp_from_client "$ADDR:80")"
  assert "the shop's Envoy (:8080), directly from the client pod" "blocked" "$(tcp_from_client "envoy.$NS.svc:8080")"
  assert "the echo app (:8080), directly"                          "blocked" "$(tcp_from_client "echo.$NS.svc:8080")"
  assert "the kiosk (:8080), directly"                             "blocked" "$(tcp_from_client "kiosk.$NS.svc:8080")"
  assert "the inventory, gRPC (:50051), directly"                  "blocked" "$(tcp_from_client "inventory.$NS.svc:50051")"
  assert "MongoDB (:27017), directly"                              "blocked" "$(tcp_from_client "inventory-db.$NS.svc:27017")"
  # A fresh token: section 6's are older than their 300 s by now.
  assert_contains "the same call through the Gateway, with a JWT -> 200" " -> 200" \
    "$(with_token "$($TOKEN shop.alice)" GET /v1/items -o /dev/null)"

  say "8. no token or password in a process's arguments"
  local audit
  audit=$(printf '%s\n' "${OLD##*.}" "${CA##*.}" "${CB##*.}" "${TUT##*.}" "Ldap123" | exec_audit "$since")
  assert "pod exec requests the API server recorded during this check (their URLs hold the arguments): some" "yes" \
    "$([ "${audit%% *}" -gt 0 ] 2>/dev/null && echo yes || echo "no ($audit)")"
  assert "...none holds a token's signature or the password" "0" "${audit#* }"
  # The sessions' cookie jars and the last login page, left in the client pod by browser.sh.
  incluster_sh 'rm -f /tmp/*.gateway.jar /tmp/*.keycloak.jar /tmp/*.page'
  summary
}

# unforward - remove the laptop's forward $LOCAL, but only the one to this Gateway's
# address: the same port forwarded anywhere else is someone else's. Sets $forwarded to
# what became of it; exits 1, having changed nothing, when it cannot tell whose it is.
unforward() {
  local rc=0 out addr
  if ! addr=$($KUBE get gateway/eg -n "$NS" -o jsonpath='{.status.addresses[0].value}' 2>&1); then
    case "$addr" in
      (*NotFound*) addr= ;;
      (*) bad "cannot read Gateway $NS/eg, so not where its forward $LOCAL leads - nothing removed: $addr"; exit 1 ;;
    esac
  fi
  if [ -n "$addr" ]; then
    out=$(../_shared/crc-forward.sh remove "$LOCAL" "$addr:80" 2>&1) || rc=$?
  else
    # No Gateway address to name: a forward still on the port cannot be shown to be ours.
    out=$(../_shared/crc-forward.sh get "$LOCAL" 2>&1) || rc=$?
    if [ $rc -eq 0 ] && [ -n "$out" ]; then
      bad "Gateway $NS/eg has no address, but $LOCAL still forwards to $out - left alone. If it is this module's, remove it with: ../_shared/crc-forward.sh remove $LOCAL $out"
      exit 1
    fi
  fi
  case $rc in
    0) case "$out" in (*"forward removed"*) forwarded="removed" ;; (*) forwarded="was not there" ;; esac ;;
    3) forwarded="not on this machine (not CRC)" ;;
    *) bad "cannot remove the laptop's forward $LOCAL: $out"; exit 1 ;;
  esac
}

clean() {
  local forwarded
  unforward
  # Argo CD would put everything back as it is deleted.
  app_pause "$APP"
  gw_down "$NS" eg || exit 1
  checked "delete the ReferenceGrant in keycloak" \
    "$KUBE" delete -f manifests/50-trust-keycloak.yaml --ignore-not-found
  checked "delete namespace $NS" \
    "$KUBE" delete -f manifests/10-gateway.yaml --ignore-not-found --wait=false
  gone "namespace $NS" "ns/$NS"
  ok "namespace $NS deleted, with the shop and its database claim; the laptop's forward $LOCAL $forwarded; realm corp and its client shop-kiosk stay (module 18)"
}

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  pause) app_pause "$APP" ;; resume) app_resume "$APP" ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
