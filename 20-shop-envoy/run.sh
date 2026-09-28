#!/usr/bin/env bash
# Module 20 — the shop behind a standalone Envoy on an OpenShift Route.  ./run.sh deploy | verify | clean | pause | resume
cd "$(dirname "$0")" || exit 1
NS=envoy-20
. ../_shared/lib.sh
. ../_shared/argocd.sh

APP=20-shop-envoy
CORP=https://keycloak.apps-crc.testing/realms/corp
TOKEN=../17-keycloak-jwt/token.sh
KC_ADMIN=../18-keycloak-ldap/admin.sh
# Where a browser on the laptop reaches the shop, and so what realm corp sends it back
# to (the client's redirect URI, the oauth2 filter's redirect_uri): the Route's host,
# on the port of the ingress shard's forward.
SHOP=https://shop.apps-metallb.crc.testing:20443
# The shard's forward from the laptop - the shard's own (its run.sh makes and removes
# it); this module only reads it.
LOCAL=127.0.0.1:20443
# The shop and what walls it in - applied before anything leads to it.
APPLY="20-shop-db-secret 21-shop-database 22-shop-inventory-src 23-shop-inventory 24-shop-envoy-config
       25-shop-envoy-proto 26-shop-envoy 27-shop-kiosk-src 28-shop-kiosk 30-network-policy"

# envoy_client - realm corp's client shop-envoy as "<redirect URIs> <PKCE method>", or
# nothing when there is none.
envoy_client() {
  $KC_ADMIN GET '/admin/realms/corp/clients?clientId=shop-envoy' 2>/dev/null | python3 -c '
import json, sys
for c in json.load(sys.stdin):
    print(",".join(c["redirectUris"]), c["attributes"].get("pkce.code.challenge.method", "-"))' 2>/dev/null
}
# shard_address - the ingress shard's MetalLB address (its router's Service), or nothing.
shard_address() {
  $KUBE get svc router-metallb -n openshift-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null
}
# What this module builds on: module 16's Keycloak, module 18's realm corp with the
# client shop-envoy and its Secret (README step 2), and the MetalLB ingress shard.
need_lab() {
  [ "$($KUBE get keycloak keycloak -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] \
    || { bad "module 16's Keycloak is not running - ../16-keycloak/run.sh deploy"; exit 1; }
  [ "$($KUBE get keycloakrealmimport corp -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null)" = True ] \
    || { bad "realm corp is not imported - ../18-keycloak-ldap/run.sh deploy"; exit 1; }
  [ -n "$(envoy_client)" ] \
    || { bad "realm corp has no client shop-envoy - README step 2 re-imports corp with it"; exit 1; }
  $KUBE get secret shop-envoy-client -n keycloak >/dev/null 2>&1 \
    || { bad "no Secret shop-envoy-client in keycloak - ../18-keycloak-ldap/run.sh deploy makes it"; exit 1; }
  [ "$($KUBE get ingresscontroller metallb -n openshift-ingress-operator -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" = True ] \
    && [ -n "$(shard_address)" ] \
    || { bad "the MetalLB ingress shard is not up - ../00-prerequisites/ingress-shard/run.sh deploy"; exit 1; }
}

# front_envoy_inputs - what the front Envoy reads when it starts, and never again: its
# configuration, the oauth2 filter's two Secrets, and the CA it trusts Keycloak with.
FRONT_ENVOY_INPUTS="configmap/front-envoy-config secret/shop-envoy-client secret/shop-envoy-hmac configmap/keycloak-ca"
# front_envoy_stale - "no" when the running front Envoy has the inputs the cluster
# holds now; otherwise "yes (why)". Envoy reads its files once, at start, so:
# - envoy.yaml is a subPath mount, which the kubelet never refreshes: the file in
#   the pod IS what Envoy started with. Compare its content with the ConfigMap
#   (a hash each side; the pod's own sha256sum). Timestamps cannot do this: an
#   Argo CD sync writes the ConfigMap and the rollout starts in the same second
#   (measured 2026-09-28, both 11:58:10Z), which no clock can order.
# - the Secrets and the CA are directory mounts the kubelet does refresh, so their
#   content in the pod proves nothing about what Envoy loaded: for them, the pod
#   must have started after their last write. run.sh writes them itself, before
#   any restart, never in the same second as a sync.
# Reads metadata and hashes only; no secret leaves the cluster in clear. A
# partial read never counts as current.
front_envoy_stale() {
  local pod want have written started
  # A pod being deleted is the old one after a rollout; skip it (jsonpath cannot
  # test for an absent field, so filter the pair name|deletionTimestamp here).
  pod=$($KUBE get pods -n "$NS" -l app=front-envoy \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
    | awk -F'|' '$2 == "" { print $1; exit }')
  [ -n "$pod" ] || { echo "yes (no running front Envoy pod)"; return; }
  want=$($KUBE get configmap front-envoy-config -n "$NS" -o jsonpath='{.data.envoy\.yaml}' 2>/dev/null | shasum -a 256 | cut -c1-64)
  have=$($KUBE exec -n "$NS" "$pod" -- sha256sum /etc/envoy/envoy.yaml 2>/dev/null | cut -c1-64)
  { [ -n "$want" ] && [ -n "$have" ]; } || { echo "yes (cannot hash the configuration on both sides)"; return; }
  [ "$want" = "$have" ] || { echo "yes (the ConfigMap changed since Envoy read it)"; return; }
  written=$($KUBE get secret/shop-envoy-client secret/shop-envoy-hmac configmap/keycloak-ca -n "$NS" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .metadata.managedFields[*]}{.time}{" "}{end}{"\n"}{end}' 2>/dev/null) \
    || { echo "yes (cannot read the Secrets and CA)"; return; }
  started=$($KUBE get pod "$pod" -n "$NS" -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null)
  python3 -c '
import datetime, sys
def stamp(s):
    d = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    if d.tzinfo is None:
        raise ValueError()
    return d
try:
    rows = [line.split("|", 1) for line in sys.stdin.read().splitlines()]
    if {r[0] for r in rows} != {"shop-envoy-client", "shop-envoy-hmac", "keycloak-ca"}:
        raise ValueError()
    writes = [stamp(t) for _, times in rows for t in times.split()]
    if not writes:
        raise ValueError()
    start = stamp(sys.argv[1])
    print("no" if max(writes) < start else "yes (a Secret or the CA was written after Envoy started)")
except (ValueError, IndexError):
    print("yes (incomplete Secret, CA or pod timestamps)")' "$started" <<<"$written"
}

# Also called after app_resume: a sync may write inputs after the first check.
front_envoy_current() {
  if [ "$(front_envoy_stale)" != no ]; then
    $KUBE rollout restart deploy/front-envoy -n "$NS" >/dev/null \
      || { bad "the front Envoy could not be restarted"; exit 1; }
  fi
  wait_ready front-envoy
  [ "$(front_envoy_stale)" = no ] \
    || { bad "cannot establish that front Envoy runs current inputs: $(front_envoy_stale)"; exit 1; }
}

# secrets_write - the front Envoy's inputs that are not in git (README step 6):
#   Secret shop-envoy-client  a copy of module 18's keycloak/shop-envoy-client
#   Secret shop-envoy-hmac    the key its session cookies are signed with: a random value,
#                             once, never replaced - a new one signs every session out
#   ConfigMap keycloak-ca     the CA Keycloak's certificate chains to, from Secret
#                             keycloak/keycloak-tls (a certificate, no key)
# Every value goes from one object to the other through a pipe, never an argument.
secrets_write() {
  local v
  v=$($KUBE get secret shop-envoy-client -n keycloak -o jsonpath='{.data.client-secret}' 2>/dev/null)
  [ -n "$v" ] || { bad "no Secret shop-envoy-client in keycloak - ../18-keycloak-ldap/run.sh deploy makes it"; exit 1; }
  printf '%s' "$v" | base64 -d \
    | $KUBE create secret generic shop-envoy-client -n "$NS" --from-file=client-secret=/dev/stdin --dry-run=client -o yaml \
    | $KUBE apply -f - >/dev/null || { bad "Secret shop-envoy-client could not be written"; exit 1; }
  if ! $KUBE get secret shop-envoy-hmac -n "$NS" >/dev/null 2>&1; then
    python3 -c 'import secrets; print(secrets.token_urlsafe(32), end="")' \
      | $KUBE create secret generic shop-envoy-hmac -n "$NS" --from-file=hmac-secret=/dev/stdin >/dev/null \
      || { bad "Secret shop-envoy-hmac could not be created"; exit 1; }
  fi
  $KUBE get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d \
    | $KUBE create configmap keycloak-ca -n "$NS" --from-file=ca.crt=/dev/stdin --dry-run=client -o yaml \
    | $KUBE apply -f - >/dev/null || { bad "ConfigMap keycloak-ca could not be written"; exit 1; }
}

# shop_forward - "<local> -> <shard address>:443" when the shard's forward is in place,
# "not CRC" where there is no CRC to ask; anything else fails. Read only: the forward is
# the shard's (../00-prerequisites/ingress-shard/run.sh deploy makes it).
shop_forward() {
  local out rc=0
  out=$(../_shared/crc-forward.sh get "$LOCAL" 2>&1) || rc=$?
  case $rc in
    0) [ "$out" = "$(shard_address):443" ] && echo "$LOCAL -> $out" \
         || echo "$LOCAL forwards to [${out:-nothing}], not the shard's $(shard_address):443 - ../00-prerequisites/ingress-shard/run.sh deploy" ;;
    3) echo "not CRC" ;;
    *) echo "cannot read CRC's forwards: $out" ;;
  esac
}

deploy() {
  need_lab
  say "deploying into $NS"
  ns_ensure || { bad "cannot create namespace $NS"; exit 1; }
  $KUBE apply -f manifests/10-namespace.yaml >/dev/null || { bad "namespace $NS could not be applied"; exit 1; }
  # 1. The shop and its NetworkPolicies. Nothing leads to it yet.
  local f
  for f in $APPLY; do
    $KUBE apply -f "manifests/$f.yaml" >/dev/null || { bad "manifests/$f.yaml could not be applied"; exit 1; }
  done
  $KUBE apply -n "$NS" -f ../_shared/client.yaml -f ../_shared/echo-app.yaml >/dev/null \
    || { bad "the client pod and the echo app could not be applied"; exit 1; }
  # The inventory installs its Python packages at start (23-shop-inventory.yaml).
  wait_ready inventory-db 300s; wait_ready inventory 300s; wait_ready envoy; wait_ready kiosk; wait_ready echo
  client_ready
  # 2. The front Envoy, with its sign-in, its secrets and its CA, running before any
  #    Route leads to it; restarted when it predates one of them (it reads them once).
  secrets_write
  $KUBE apply -f manifests/70-front-envoy-config.yaml -f manifests/71-front-envoy.yaml >/dev/null \
    || { bad "the front Envoy could not be applied - no Route published"; exit 1; }
  # Restart stale/unreadable pods before waiting: a corrected ConfigMap cannot
  # repair an old subPath mount in a CrashLooping pod.
  front_envoy_current
  # 3. Only now the Route.
  $KUBE apply -f manifests/80-route.yaml >/dev/null || { bad "Route shop could not be applied"; exit 1; }
  local admitted=
  for _ in $(seq 1 30); do
    admitted=$($KUBE get route shop -n "$NS" -o jsonpath='{.status.ingress[?(@.routerName=="metallb")].conditions[?(@.type=="Admitted")].status}')
    [ "$admitted" = True ] && break
    sleep 2
  done
  [ "$admitted" = True ] || { bad "Route shop not admitted by the shard - oc get route shop -n $NS -o yaml"; exit 1; }
  # The first calls can fail while the router loads the Route and the shop's Envoy
  # finds the inventory: wait, a minute at most, until a signed-in call gets the shop's
  # answer.
  local tok code=
  tok=$($TOKEN shop.alice) || { bad "no token for shop.alice from realm corp"; exit 1; }
  for _ in $(seq 1 30); do
    code=$(printf '%s\n' "$tok" | ADDR=$(shard_address) ./request.sh GET /v1/items -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$code" = 200 ] && break
    sleep 2
  done
  [ "$code" = 200 ] || { bad "the shop never answered through the Route (last: ${code:-none})"; exit 1; }
  local fwd; fwd=$(shop_forward)
  case "$fwd" in
    "$LOCAL -> "*) ok "the shop is up behind Route shop; in a browser: $SHOP" ;;
    "not CRC") ok "the shop is up behind Route shop, at the shard's address $(shard_address), port 443" ;;
    *) bad "$fwd"; exit 1 ;;
  esac
  app_resume "$APP"
  front_envoy_current
}

# claims - the JWT on stdin, as "name value" lines: iss, azp, preferred_username, exp,
# aud and roles (sorted, space-separated). On stdin, never in python's argv.
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
# forwarded - the bearer token the front Envoy sent on to the app, from the echo at
# /whoami (the response body on stdin).
forwarded() { python3 -c 'import json, sys; print(json.load(sys.stdin)["headers"].get("authorization", "").removeprefix("Bearer "))' 2>/dev/null; }
# echoed <header> - one request header the app got, from the echo at /whoami (stdin).
echoed() { python3 -c 'import json, sys; print(json.load(sys.stdin)["headers"].get(sys.argv[1], "(none)"))' "$1" 2>/dev/null; }

# as_browser <user> <METHOD> <path> [curl args...] - status of a call with the user's session.
as_browser() { ./browser.sh "$@" -o /dev/null -w '%{http_code}'; }
# with_token <token> <METHOD> <path> [curl args...] - body, then " -> <status>". The
# token goes to request.sh on stdin (a shell function's arguments are no process's).
with_token() { local t=$1; shift; printf '%s\n' "$t" | ./request.sh "$@" -w ' -> %{http_code}' 2>/dev/null; }
# with_token_19 - the same, at module 19's Gateway (its own request.sh; its address,
# $ADDR19, which verify reads).
with_token_19() { local t=$1; shift; printf '%s\n' "$t" | ADDR=$ADDR19 ../19-shop-gateway/request.sh "$@" -w ' -> %{http_code}' 2>/dev/null; }
JSON=(-H 'content-type: application/json')
# side <what> <token> <METHOD> <path> [curl args...] - the same request, with the same
# token, at module 19's Gateway and at this module's Route: the answers (body and status)
# must be the same. A 200 carries the shop's own data - the same code, another database -
# so for a 200 only the status is compared.
side() {
  local what=$1 t=$2 a19 a20
  shift 2
  a19=$(with_token_19 "$t" "$@"); a20=$(with_token "$t" "$@")
  case "$a20" in (*" -> 200") a19=${a19##* -> }; a20=${a20##* -> } ;; esac
  assert "$what: at 19 [$a19], at 20 the same" "$a19" "$a20"
}

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

# gate_refusal <since> <user> - why Keycloak refused <user>'s last sign-in to corp through
# client shop-envoy, from its own log (the login page says the same for a wrong password).
gate_refusal() {
  local since=$1 user=$2 why=
  for _ in 1 2 3 4 5; do
    why=$($KUBE logs keycloak-0 -n keycloak --since-time="$since" 2>/dev/null \
      | grep LOGIN_ERROR | grep 'realmName="corp"' | grep 'clientId="shop-envoy"' | grep "username=\"$user\"" \
      | tail -n 1 | grep -o 'error="[^"]*"')
    [ -n "$why" ] && break
    sleep 1
  done
  echo "${why:-no LOGIN_ERROR for $user in keycloak-0 since $since}"
}
# exec_audit <since> - "<n> <m>": the pod exec requests in envoy-20, envoy-19 and keycloak
# that the API server's audit log recorded since <since>, and how many of them carry one
# of the secrets read on stdin, one per line. An exec's arguments are in its request URL.
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
    if e["objectRef"].get("namespace") not in ("envoy-20", "envoy-19", "keycloak") or e["requestReceivedTimestamp"] < since:
        continue
    n += 1
    m += any(s in e["requestURI"] for s in secrets)
print(n, m)' "$1" 3< <($KUBE adm node-logs --role=master --path=kube-apiserver/audit.log 2>/dev/null)
}

verify() {
  need_lab
  client_ready
  ADDR=$(shard_address); export ADDR
  local since; since=$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)
  # request.sh and browser.sh check the router's certificate with this CA.
  $KUBE get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d \
    | $KUBE exec -i -n "$NS" client -- sh -c 'cat > /tmp/ca.crt' || { bad "cannot copy the CA into the client pod"; exit 1; }

  # Prove both ends with the SAME unmodified signed token. Decode only to
  # measure its lifetime; the successful request proves Envoy accepted it.
  local OLD OLD_EXP
  OLD=$(./expiry-token.sh) || { bad "cannot obtain the expiry probe token"; exit 1; }
  OLD_EXP=$(python3 -c '
import base64, json, sys
try:
    part = sys.stdin.read().strip().split(".")[1]
    c = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
    assert c["azp"] == "shop-envoy-cli"
    assert type(c["exp"]) is int and type(c["iat"]) is int
    # Token creation may cross a second boundary between issuedNow and exp.
    assert 45 <= c["exp"] - c["iat"] <= 46
except (ValueError, KeyError, IndexError, TypeError, AssertionError):
    sys.exit("expected shop-envoy-cli exp-iat = 45 s (46 at a second boundary); re-import corp: module 18 step 13")
print(c["exp"])' <<<"$OLD") || { bad "expiry probe lifetime was not confirmed"; exit 1; }
  [ "$(with_token "$OLD" GET /v1/items -o /dev/null)" = " -> 200" ] \
    || { bad "expiry probe token was not accepted while fresh"; exit 1; }

  say "1. the objects, and the filters the front Envoy runs"
  assert "Route shop: admitted by the MetalLB ingress shard, and by no other router" "metallb=True" \
    "$($KUBE get route shop -n "$NS" -o jsonpath='{range .status.ingress[*]}{.routerName}={.conditions[?(@.type=="Admitted")].status}{" "}{end}' | sed 's/ $//')"
  assert "...edge TLS, to the front Envoy" "edge front-envoy" \
    "$($KUBE get route shop -n "$NS" -o jsonpath='{.spec.tls.termination} {.spec.to.name}')"
  assert "the front Envoy is ready" "1" \
    "$($KUBE get deploy front-envoy -n "$NS" -o jsonpath='{.status.readyReplicas}')"
  assert "its client secret is module 18's (Secret shop-envoy-client = keycloak/shop-envoy-client)" "same" \
    "$([ -n "$($KUBE get secret shop-envoy-client -n "$NS" -o jsonpath='{.data.client-secret}' 2>/dev/null)" ] \
       && [ "$($KUBE get secret shop-envoy-client -n "$NS" -o jsonpath='{.data.client-secret}')" = "$($KUBE get secret shop-envoy-client -n keycloak -o jsonpath='{.data.client-secret}')" ] \
       && echo same || echo differ)"
  assert "its cookie-signing key (Secret shop-envoy-hmac) holds 32 random bytes or more" "yes" \
    "$([ "$($KUBE get secret shop-envoy-hmac -n "$NS" -o jsonpath='{.data.hmac-secret}' 2>/dev/null | base64 -d | wc -c | tr -d ' ')" -ge 43 ] 2>/dev/null && echo yes || echo no)"
  assert "it trusts Keycloak's CA (ConfigMap keycloak-ca = Secret keycloak/keycloak-tls's ca.crt)" "same" \
    "$([ -n "$($KUBE get configmap keycloak-ca -n "$NS" -o jsonpath='{.data.ca\.crt}' 2>/dev/null)" ] \
       && [ "$($KUBE get configmap keycloak-ca -n "$NS" -o jsonpath='{.data.ca\.crt}')" = "$($KUBE get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d)" ] \
       && echo same || echo differ)"
  assert "it runs the configuration, Secrets and CA the cluster holds now" "no" "$(front_envoy_stale)"
  assert "realm corp's client shop-envoy: its redirect URI, PKCE S256" "$SHOP/oauth2/callback S256" "$(envoy_client)"
  assert "the front Envoy's filter chain: oauth2, jwt_authn, rbac, router" \
    "envoy.filters.http.oauth2 envoy.filters.http.jwt_authn envoy.filters.http.rbac envoy.filters.http.router" \
    "$(./admin.sh 'config_dump?resource=static_listeners' 2>/dev/null | python3 -c 'import json, sys; l = json.load(sys.stdin)["configs"][0]["listener"]; print(" ".join(f["name"] for f in l["filter_chains"][0]["filters"][0]["typed_config"]["http_filters"]))' 2>/dev/null)"

  assert "corp JWT provider: explicit 5 s clock skew" "5" \
    "$(./admin.sh 'config_dump?resource=static_listeners' | python3 -c 'import json,sys; l=json.load(sys.stdin)["configs"][0]["listener"]; fs=l["filter_chains"][0]["filters"][0]["typed_config"]["http_filters"]; print(next(f for f in fs if f["name"] == "envoy.filters.http.jwt_authn")["typed_config"]["providers"]["corp"].get("clock_skew_seconds", "default"))')"

  say "2. a browser with no session is sent to realm corp's login page"
  local fwd; fwd=$(shop_forward)
  case "$fwd" in
    "$LOCAL -> "*)
      ok "the ingress shard's forward: $fwd"
      assert_contains "from this laptop, $SHOP/ -> 302 to corp's login page" "302 $CORP/protocol/openid-connect/auth?" \
        "$(curl -s -m 10 --cacert <($KUBE get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d) -o /dev/null -w '%{http_code} %{redirect_url}' "$SHOP/")" ;;
    "not CRC") echo "  note: not CRC - a browser must reach the shard's address $ADDR itself" ;;
    *) bad "$fwd"; FAILED=$((FAILED+1)) ;;
  esac
  local R; R=$(incluster_curl --cacert /tmp/ca.crt -o /dev/null -w '%{http_code} %{redirect_url}' \
    --connect-to "shop.apps-metallb.crc.testing:20443:$ADDR:443" "$SHOP/")
  assert_contains "GET / -> 302 to corp's authorization endpoint" "302 $CORP/protocol/openid-connect/auth?" "$R"
  assert_contains "...as client shop-envoy"            "client_id=shop-envoy"                  "$R"
  assert_contains "...with a PKCE S256 challenge"      "code_challenge_method=S256"            "$R"
  assert_contains "...and the Route's address to come back to" \
    "redirect_uri=https%3A%2F%2Fshop.apps-metallb.crc.testing%3A20443%2Foauth2%2Fcallback" "$R"

  say "3. shop.alice signs in: she may list and reserve, not create, delete or reset"
  assert "shop.alice signs in on corp's login page" "0" "$(./browser.sh sign-in shop.alice >/dev/null 2>&1; echo $?)"
  local W; W=$(./browser.sh shop.alice GET /whoami)
  local A; A=$(forwarded <<<"$W" | claims)
  assert "her JWT, as the front Envoy sent it on: issued by corp" "$CORP"      "$(claim iss "$A")"
  assert "...to the front Envoy's client"                         "shop-envoy" "$(claim azp "$A")"
  assert "...for the shop's API (aud shop-api)"                   "yes"        "$(has shop-api "$(claim aud "$A")")"
  assert "...as shop.alice, without admin"                        "shop.alice no" "$(claim preferred_username "$A") $(has admin "$(claim roles "$A")")"
  assert "...and no session cookie reaches the app"               "(none)"     "$(echoed cookie <<<"$W")"
  assert "GET /v1/items -> 200"                      "200" "$(as_browser shop.alice GET /v1/items)"
  assert "GET /v1/warehouses -> 200"                 "200" "$(as_browser shop.alice GET /v1/warehouses)"
  local SKU_B; SKU_B="VERIFY-20-B-$(date +%s)"
  assert_contains "(shop.bob makes a disposable item, $SKU_B)" " -> 200" "$(item create "$SKU_B")"
  assert "POST /v1/items/$SKU_B:reserve -> reserved (ok true, 1 reserved)" "ok true reserved 1" \
    "$(./browser.sh shop.alice POST "/v1/items/$SKU_B:reserve" "${JSON[@]}" -d '{"quantity":1,"orderId":"VERIFY-20"}' | reserved)"
  assert "POST /v1/items (create) -> 403"            "403" "$(as_browser shop.alice POST /v1/items "${JSON[@]}" -d '{"sku":"SKU-V20","name":"verify","onHand":1,"warehouse":"LEEDS"}')"
  assert "DELETE /v1/items/$SKU_B -> 403"            "403" "$(as_browser shop.alice DELETE "/v1/items/$SKU_B")"
  assert "POST /v1/items:reset -> 403"               "403" "$(as_browser shop.alice POST /v1/items:reset "${JSON[@]}" -d '{}')"

  say "4. shop.bob signs in: admin, from his LDAP group - he may create and delete"
  assert "shop.bob signs in on corp's login page" "0" "$(./browser.sh sign-in shop.bob >/dev/null 2>&1; echo $?)"
  local B; B=$(./browser.sh shop.bob GET /whoami | forwarded | claims)
  assert "his JWT: issued by corp, for shop-api, with admin" "$CORP yes yes" \
    "$(claim iss "$B") $(has shop-api "$(claim aud "$B")") $(has admin "$(claim roles "$B")")"
  assert "POST /v1/items (create SKU-V20) -> 200"    "200" "$(as_browser shop.bob POST /v1/items "${JSON[@]}" -d '{"sku":"SKU-V20","name":"verify","onHand":1,"warehouse":"LEEDS"}')"
  assert "DELETE /v1/items/SKU-V20 -> 200"           "200" "$(as_browser shop.bob DELETE /v1/items/SKU-V20)"
  assert "POST /v1/items:reset -> 200"               "200" "$(as_browser shop.bob POST /v1/items:reset "${JSON[@]}" -d '{}')"
  assert "DELETE /v1/items/$SKU_B (the disposable item) -> 200" "200" "$(as_browser shop.bob DELETE "/v1/items/$SKU_B")"
  assert "shop.bob signs out: back to corp's logout, then the shop" "2. corp logout -> 302, to $SHOP/" \
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
  local SKU_C; SKU_C="VERIFY-20-C-$(date +%s)"
  assert_contains "(shop.bob makes a disposable item, $SKU_C)" " -> 200" "$(item create "$SKU_C")"
  assert "shop.alice: reserve -> reserved (ok true, 1 reserved)" "ok true reserved 1" \
    "$(printf '%s\n' "$CA" | ./request.sh POST "/v1/items/$SKU_C:reserve" "${JSON[@]}" -d '{"quantity":1,"orderId":"VERIFY-20"}' 2>/dev/null | reserved)"
  assert_contains "shop.alice: create -> 403 RBAC"             "RBAC: access denied -> 403" "$(with_token "$CA" POST /v1/items "${JSON[@]}" -d '{"sku":"SKU-V20","name":"verify","onHand":1,"warehouse":"LEEDS"}')"
  assert_contains "shop.alice: delete -> 403 RBAC"             "RBAC: access denied -> 403" "$(with_token "$CA" DELETE "/v1/items/$SKU_C")"
  assert_contains "shop.alice: reset -> 403 RBAC"              "RBAC: access denied -> 403" "$(with_token "$CA" POST /v1/items:reset "${JSON[@]}" -d '{}')"
  assert_contains "shop.bob: create -> 200"                    " -> 200" "$(with_token "$CB" POST /v1/items "${JSON[@]}" -d '{"sku":"SKU-V20","name":"verify","onHand":1,"warehouse":"LEEDS"}' -o /dev/null)"
  assert_contains "shop.bob: delete -> 200"                    " -> 200" "$(with_token "$CB" DELETE /v1/items/SKU-V20 -o /dev/null)"
  # Requests shaped to slip past the reserve rule, as shop.alice, sent exactly as
  # written (--path-as-is). Each must stop at the front Envoy (README, step 12) - the
  # same set, and the same answers, as module 19's verify.
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

  say "7. side by side with module 19: the same requests, the same answers"
  ADDR19=$($KUBE get gateway eg -n envoy-19 -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
  if [ -z "$ADDR19" ]; then
    echo "  note: module 19's Gateway is not deployed - nothing to compare with"
  else
    side "shop.alice GET /v1/items"               "$CA" GET /v1/items -o /dev/null
    side "shop.alice POST /v1/items (create)"     "$CA" POST /v1/items "${JSON[@]}" -d '{"sku":"SKU-S20","name":"side","onHand":1,"warehouse":"LEEDS"}'
    side "shop.alice POST /v1/items:reset"        "$CA" POST /v1/items:reset "${JSON[@]}" -d '{}'
    side "shop.alice PATCH /v1/items/SKU-1001"    "$CA" PATCH /v1/items/SKU-1001 "${JSON[@]}" -d '{"onHand":99}'
    side "shop.alice POST .../SKU-1001:restock"   "$CA" POST /v1/items/SKU-1001:restock "${JSON[@]}" -d '{}'
    side "shop.alice POST .../SKU-1001:reserve?x=1" "$CA" POST '/v1/items/SKU-1001:reserve?x=1' --path-as-is "${JSON[@]}" -d '{}'
    side "shop.alice POST .../SKU-1001%2Fx:reserve" "$CA" POST '/v1/items/SKU-1001%2Fx:reserve' --path-as-is -o /dev/null "${JSON[@]}" -d '{}'
    side "shop.alice post (lower case) .../SKU-1001:reserve" "$CA" POST /v1/items/SKU-1001:reserve -X post "${JSON[@]}" -d '{}'
    side "shop.bob GET /v1/warehouses"            "$CB" GET /v1/warehouses -o /dev/null
    side "the edited JWT, GET /v1/items"          "$TAMPERED" GET /v1/items
    side "the realm tutorial JWT, GET /v1/items"  "$TUT" GET /v1/items
  fi

  say "8. the directory decides, at every login"
  assert "realm corp's LDAP provider reads the directory at every login (cachePolicy)" "NO_CACHE" \
    "$($KC_ADMIN GET '/admin/realms/corp/components?type=org.keycloak.storage.UserStorageProvider&name=ldap' 2>/dev/null \
       | python3 -c 'import json, sys; c = json.load(sys.stdin); print(c[0]["config"].get("cachePolicy", ["DEFAULT (not set)"])[0] if len(c) == 1 else "unknown")' 2>/dev/null)"
  echo "  (the change itself - shop.bob out of the admin group and back - is README step 13: verify does not change the directory)"

  say "9. an expired JWT"
  local wait_s; wait_s=$(( OLD_EXP + 5 + 5 - $(date +%s) ))
  [ "$wait_s" -le 60 ] || { bad "expiry wait exceeds 60 s: check laptop/CRC clocks"; exit 1; }
  if [ "$wait_s" -gt 0 ]; then
    echo "  (waiting ${wait_s} s: exp + 5 s provider skew + 5 s margin)"
    sleep "$wait_s"
  fi
  assert_contains "shop.alice's JWT once it has expired -> 401" "Jwt is expired -> 401" "$(with_token "$OLD" GET /v1/items)"

  say "10. the Route is the only way in"
  assert "the probe itself: the shard's address, port 443, from the client pod" "reachable" "$(tcp_from_client "$ADDR:443")"
  assert "the front Envoy (:8080), directly from the client pod"   "blocked" "$(tcp_from_client "front-envoy.$NS.svc:8080")"
  assert "the shop's Envoy (:8080), directly"                      "blocked" "$(tcp_from_client "envoy.$NS.svc:8080")"
  assert "the echo app (:8080), directly"                          "blocked" "$(tcp_from_client "echo.$NS.svc:8080")"
  assert "the kiosk (:8080), directly"                             "blocked" "$(tcp_from_client "kiosk.$NS.svc:8080")"
  assert "the inventory, gRPC (:50051), directly"                  "blocked" "$(tcp_from_client "inventory.$NS.svc:50051")"
  assert "MongoDB (:27017), directly"                              "blocked" "$(tcp_from_client "inventory-db.$NS.svc:27017")"
  # A fresh token: section 6's are older than their 300 s by now.
  assert_contains "the same call through the Route, with a JWT -> 200" " -> 200" \
    "$(with_token "$($TOKEN shop.alice)" GET /v1/items -o /dev/null)"

  say "11. no token or password in a process's arguments"
  local audit
  audit=$(printf '%s\n' "${OLD##*.}" "${CA##*.}" "${CB##*.}" "${TUT##*.}" "Ldap123" | exec_audit "$since")
  assert "pod exec requests the API server recorded during this check (their URLs hold the arguments): some" "yes" \
    "$([ "${audit%% *}" -gt 0 ] 2>/dev/null && echo yes || echo "no ($audit)")"
  assert "...none holds a token's signature or the password" "0" "${audit#* }"
  # The sessions' cookie jars and the last login page, left in the client pod by browser.sh.
  incluster_sh 'rm -f /tmp/*.envoy.jar /tmp/*.keycloak.jar /tmp/*.page'
  summary
}

clean() {
  # Argo CD would put everything back as it is deleted.
  app_pause "$APP"
  checked "delete namespace $NS" \
    "$KUBE" delete -f manifests/10-namespace.yaml --ignore-not-found --wait=false
  gone "namespace $NS" "ns/$NS"
  ok "namespace $NS deleted, with the shop, its front Envoy, its Route and its database claim; realm corp's client shop-envoy stays (module 18), and so do the ingress shard and its forward $LOCAL"
}

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  pause) app_pause "$APP" ;; resume) app_resume "$APP" ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
