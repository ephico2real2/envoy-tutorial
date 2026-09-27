#!/usr/bin/env bash
# Module 16 — a Keycloak lab (Red Hat build of Keycloak).  ./run.sh deploy | verify | clean [--delete-data] | pause | resume
cd "$(dirname "$0")"
NS=keycloak
. ../_shared/lib.sh
. ../_shared/argocd.sh

REALM=https://keycloak.apps-crc.testing/realms/tutorial

# The operator version this Subscription installed. Not "every CSV in the
# namespace": OLM copies the CSVs of cluster-wide operators into each one.
installed_csv() { $KUBE get subscription rhbk-operator -n "$NS" -o jsonpath='{.status.installedCSV}' 2>/dev/null; }

deploy() {
  say "deploying the Keycloak lab into $NS"
  $KUBE apply -f manifests/10-operator.yaml >/dev/null
  # Manual approval: approve the InstallPlan this Subscription is waiting on.
  local plan= phase=
  for _ in $(seq 1 60); do
    plan=$($KUBE get subscription rhbk-operator -n "$NS" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null)
    [ -n "$plan" ] && break; sleep 5
  done
  [ -n "$plan" ] || { bad "the Subscription never got an InstallPlan - is redhat-operators healthy?"; exit 1; }
  $KUBE patch installplan "$plan" -n "$NS" --type=merge -p '{"spec":{"approved":true}}' >/dev/null
  for _ in $(seq 1 60); do
    phase=$($KUBE get csv "$(installed_csv)" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$phase" = Succeeded ] && break; sleep 5
  done
  [ "$phase" = Succeeded ] || { bad "the operator never installed (CSV phase: ${phase:-none})"; exit 1; }
  ok "operator installed"
  $KUBE apply -f manifests/20-postgres.yaml -f manifests/30-certificate.yaml >/dev/null
  $KUBE rollout status statefulset/postgres -n "$NS" --timeout=300s >/dev/null
  $KUBE wait certificate/keycloak-tls -n "$NS" --for=condition=Ready --timeout=120s >/dev/null
  $KUBE apply -f manifests/40-keycloak.yaml >/dev/null
  $KUBE wait keycloak/keycloak -n "$NS" --for=condition=Ready --timeout=600s >/dev/null \
    || { bad "Keycloak never Ready - oc get keycloak keycloak -n $NS -o yaml"; exit 1; }
  $KUBE apply -f manifests/50-route.yaml -f manifests/60-realm.yaml >/dev/null
  $KUBE wait keycloakrealmimport/tutorial -n "$NS" --for=condition=Done --timeout=300s >/dev/null \
    || { bad "the realm import did not finish"; exit 1; }
  ok "Keycloak ready at https://keycloak.apps-crc.testing, realm tutorial imported"
  app_resume 16-keycloak
}

# kc <curl args...> - curl from the client pod, trusting only the enterprise CA.
kc() { $KUBE exec -n "$NS" client -- curl -s --cacert /tmp/ca.crt "$@"; }
# claims <token response JSON> - the access token's claims, one "name value" per line.
claims() {
  python3 -c '
import base64, json, sys
t = json.loads(sys.argv[1])
if "access_token" not in t:
    print("error", t.get("error")); sys.exit()
p = t["access_token"].split(".")[1]
c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
for k in ("iss", "aud", "azp", "preferred_username"):
    print(k, c.get(k))
print("roles", " ".join(sorted(c.get("realm_access", {}).get("roles", []))))' "$1"
}
token() { kc -d client_id="$1" "${@:2}" "$REALM/protocol/openid-connect/token"; }
# claim <name> <claims output> - that one claim's value, exactly: a role check must
# fail on an extra role, which a substring match lets through.
claim() { sed -n "s/^$1 //p" <<<"$2"; }

verify() {
  client_ensure
  $KUBE get secret keycloak-tls -n "$NS" -o jsonpath='{.data.ca\.crt}' | base64 -d \
    | $KUBE exec -i -n "$NS" client -- sh -c 'cat > /tmp/ca.crt'

  say "1. the operator and the server"
  assert "operator installed" "Succeeded" \
    "$($KUBE get csv "$(installed_csv)" -n "$NS" -o jsonpath='{.status.phase}')"
  assert "Keycloak Ready" "True" \
    "$($KUBE get keycloak keycloak -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  assert "realm import Done" "True" \
    "$($KUBE get keycloakrealmimport tutorial -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}')"

  say "2. what a token checker needs: the issuer and the signing keys"
  assert_contains "the discovery document names the issuer" "\"issuer\":\"$REALM\"" \
    "$(kc "$REALM/.well-known/openid-configuration")"
  JWKS=$(kc "$REALM/protocol/openid-connect/certs")
  assert_contains "the JWKS has an RS256 signing key" '"alg":"RS256"' "$JWKS"
  assert_contains "...reachable at the Service too, for in-cluster callers" '"alg":"RS256"' \
    "$(kc https://keycloak-service.keycloak.svc:8443/realms/tutorial/protocol/openid-connect/certs)"

  say "3. tokens"
  A=$(claims "$(token shop-cli -d grant_type=password -d username=alice -d password=alice-lab-password)")
  assert_contains "alice: issued by the realm"        "iss $REALM"      "$A"
  assert_contains "alice: for shop-api (aud)"         "aud shop-api"    "$A"
  assert          "alice: role reader only"           "reader"          "$(claim roles "$A")"
  B=$(claims "$(token shop-cli -d grant_type=password -d username=bob -d password=bob-lab-password)")
  assert          "bob: roles admin and reader"       "admin reader"    "$(claim roles "$B")"
  S=$(claims "$(token orders-service -d grant_type=client_credentials -d client_secret=orders-service-lab-secret)")
  assert_contains "orders-service: its own token"     "preferred_username service-account-orders-service" "$S"
  assert_contains "orders-service: for shop-api (aud)" "aud shop-api"   "$S"
  assert_contains "a wrong password gets no token" "error invalid_grant" \
    "$(claims "$(token shop-cli -d grant_type=password -d username=alice -d password=wrong)")"
  summary
}

# clean [--delete-data] - a deliberate reset. By default it removes the lab's
# server, operator and database pod, and KEEPS namespace keycloak and claim
# data-postgres-0: the database - realms, users, sessions - survives, and the next
# deploy starts on it. What modules 17 and 18 keep in this namespace stays too.
# --delete-data is the full wipe: the namespace, and with it the claim and the
# volume behind it, and everything modules 17 and 18 put in it.
clean() {
  local wipe='' pv CSV
  case "${1:-}" in
    "") ;;
    --delete-data) wipe=yes ;;
    *) echo "usage: ./run.sh clean [--delete-data]"; exit 2 ;;
  esac
  # Argo CD would put everything back as it is deleted. Modules 17 and 18 keep
  # objects in this namespace too, so their Applications pause with it.
  app_pause 16-keycloak 17-keycloak-jwt 18-keycloak-ldap
  warn=$($KUBE get securitypolicy -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null)
  [ -n "$warn" ] && echo "  note: SecurityPolicies that may use this Keycloak: $warn"
  if ! pv=$($KUBE get pvc data-postgres-0 -n "$NS" -o jsonpath='{.spec.volumeName}' 2>&1); then
    case "$pv" in
      (*NotFound*) pv='' ;;
      (*) bad "cannot read claim data-postgres-0 - nothing deleted: $pv"; return 1 ;;
    esac
  fi
  if [ -n "$wipe" ]; then
    echo "  --delete-data: deleting namespace $NS - the database (realms tutorial and corp, their users and"
    echo "  sessions), claim data-postgres-0${pv:+ and volume $pv}, and what modules 17 and 18 keep in $NS"
    # The volume outlives its claim here: CRC's StorageClass has reclaimPolicy
    # Retain, and an earlier clean left a Released PV - and the data on the
    # node's disk - behind (measured). Mark it Delete while the claim exists.
    if [ -n "$pv" ] && ! $KUBE patch pv "$pv" --type=merge \
         -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' >/dev/null; then
      bad "cannot mark volume $pv for deletion - nothing deleted"
      return 1
    fi
  fi
  $KUBE delete keycloakrealmimport tutorial -n "$NS" --ignore-not-found >/dev/null 2>&1
  $KUBE delete keycloak keycloak -n "$NS" --ignore-not-found --wait=true >/dev/null 2>&1
  CSV=$(installed_csv)
  $KUBE delete subscription rhbk-operator -n "$NS" --ignore-not-found >/dev/null 2>&1
  [ -n "$CSV" ] && $KUBE delete csv "$CSV" -n "$NS" --ignore-not-found >/dev/null 2>&1
  if [ -n "$wipe" ]; then
    if ! $KUBE delete ns "$NS" --wait=false >/dev/null 2>&1; then
      bad "namespace $NS could not be deleted; the full wipe did not complete"
      return 1
    fi
    ok "namespace $NS deletion requested; it removes the database and claim data-postgres-0${pv:+, and volume $pv}"
  else
    # Everything else this module applied, but not the Namespace (10-operator.yaml
    # holds it). Deleting the StatefulSet leaves its claim: a StatefulSet's claims
    # are kept unless persistentVolumeClaimRetentionPolicy says otherwise, and
    # 20-postgres.yaml sets none.
    $KUBE delete operatorgroup keycloak -n "$NS" --ignore-not-found >/dev/null 2>&1
    $KUBE delete -f manifests/50-route.yaml -f manifests/40-keycloak.yaml -f manifests/30-certificate.yaml \
      -f manifests/20-postgres.yaml --ignore-not-found --wait=true >/dev/null 2>&1
    if [ -n "$pv" ] && [ "$($KUBE get pvc data-postgres-0 -n "$NS" -o jsonpath='{.spec.volumeName}' 2>/dev/null)" = "$pv" ]; then
      ok "Keycloak, its operator and PostgreSQL removed; namespace $NS and claim data-postgres-0 (volume $pv) kept - the database survives"
    else
      bad "claim data-postgres-0 is not there after clean (before: ${pv:-none}) - oc get pvc -n $NS"
      return 1
    fi
    echo "  note: ./run.sh clean --delete-data also deletes the namespace, the claim and the volume"
  fi
  echo "  note: OLM leaves the CRDs keycloaks.k8s.keycloak.org and keycloakrealmimports.k8s.keycloak.org installed"
  [ -z "$(app_automated 16-keycloak)" ] \
    || echo "  note: to bring the lab back: ./run.sh deploy, then ../18-keycloak-ldap/run.sh deploy and ../17-keycloak-jwt/run.sh deploy - each resumes its Argo CD Application"
}

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean "${2:-}" ;;
  pause) app_pause 16-keycloak ;; resume) app_resume 16-keycloak ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
