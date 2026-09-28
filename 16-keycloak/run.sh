#!/usr/bin/env bash
# Module 16 — a Keycloak lab (Red Hat build of Keycloak).  ./run.sh deploy | verify | clean [--delete-data] | pause | resume
cd "$(dirname "$0")"
NS=keycloak
. ../_shared/lib.sh
. ../_shared/argocd.sh

REALM=https://keycloak.apps-crc.testing/realms/tutorial

# has_btp - 0 when the cluster serves Gateway API BackendTLSPolicies (OpenShift 4.19+
# does), 1 when it does not, 2 when the API server cannot be asked (api_serves, lib.sh).
has_btp() { api_serves gateway.networking.k8s.io backendtlspolicies; }
# gateway_trust - what every Gateway needs to reach keycloak-service over TLS: ConfigMap
# keycloak-ca, copied from Secret keycloak-tls (this cluster's CA, so not in git), and
# the BackendTLSPolicy that names it (70-backend-tls-policy.yaml). Skipped only when the
# API server answers that it serves no BackendTLSPolicy; an unanswered question fails.
gateway_trust() {
  local s=0
  has_btp || s=$?
  case $s in
    0) ;;
    1) echo "  note: no Gateway API BackendTLSPolicy on this cluster - 70-backend-tls-policy.yaml not applied"; return 0 ;;
    *) exit 1 ;;
  esac
  $KUBE create configmap keycloak-ca -n "$NS" --dry-run=client -o yaml \
    --from-literal=ca.crt="$($KUBE get secret keycloak-tls -n "$NS" -o jsonpath='{.data.ca\.crt}' | base64 -d)" \
    | $KUBE apply -f - >/dev/null || { bad "ConfigMap keycloak-ca could not be written"; exit 1; }
  $KUBE apply -f manifests/70-backend-tls-policy.yaml >/dev/null \
    || { bad "the BackendTLSPolicy to keycloak-service could not be applied"; exit 1; }
  # Not "accepted": the policy has no status until a Gateway's SecurityPolicy uses it
  # (measured, #15). Modules 17 and 19 wait for their own acceptance.
  ok "BackendTLSPolicy keycloak-service applied, trusting ConfigMap keycloak-ca - modules 17 and 19 check it accepts them"
}

# The operator version this Subscription installed. Not "every CSV in the
# namespace": OLM copies the CSVs of cluster-wide operators into each one.
installed_csv() { $KUBE get subscription rhbk-operator -n "$NS" -o jsonpath='{.status.installedCSV}' 2>/dev/null; }

deploy() {
  say "deploying the Keycloak lab into $NS"
  $KUBE apply -f manifests/10-operator.yaml >/dev/null \
    || { bad "manifests/10-operator.yaml could not be applied"; exit 1; }
  # Manual approval: approve the InstallPlan this Subscription is waiting on.
  local plan= phase=
  for _ in $(seq 1 60); do
    plan=$($KUBE get subscription rhbk-operator -n "$NS" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null)
    [ -n "$plan" ] && break; sleep 5
  done
  [ -n "$plan" ] || { bad "the Subscription never got an InstallPlan - is redhat-operators healthy?"; exit 1; }
  $KUBE patch installplan "$plan" -n "$NS" --type=merge -p '{"spec":{"approved":true}}' >/dev/null \
    || { bad "InstallPlan $plan could not be approved"; exit 1; }
  for _ in $(seq 1 60); do
    phase=$($KUBE get csv "$(installed_csv)" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$phase" = Succeeded ] && break; sleep 5
  done
  [ "$phase" = Succeeded ] || { bad "the operator never installed (CSV phase: ${phase:-none})"; exit 1; }
  ok "operator installed"
  $KUBE apply -f manifests/20-postgres.yaml -f manifests/30-certificate.yaml >/dev/null \
    || { bad "PostgreSQL and the certificate could not be applied"; exit 1; }
  $KUBE rollout status statefulset/postgres -n "$NS" --timeout=300s >/dev/null \
    || { bad "PostgreSQL never ready - oc get pods -n $NS -l app=postgres"; exit 1; }
  $KUBE wait certificate/keycloak-tls -n "$NS" --for=condition=Ready --timeout=120s >/dev/null \
    || { bad "certificate keycloak-tls never Ready - oc describe certificate keycloak-tls -n $NS"; exit 1; }
  $KUBE apply -f manifests/40-keycloak.yaml >/dev/null \
    || { bad "manifests/40-keycloak.yaml could not be applied"; exit 1; }
  $KUBE wait keycloak/keycloak -n "$NS" --for=condition=Ready --timeout=600s >/dev/null \
    || { bad "Keycloak never Ready - oc get keycloak keycloak -n $NS -o yaml"; exit 1; }
  $KUBE apply -f manifests/50-route.yaml -f manifests/60-realm.yaml >/dev/null \
    || { bad "the Route and realm import tutorial could not be applied"; exit 1; }
  $KUBE wait keycloakrealmimport/tutorial -n "$NS" --for=condition=Done --timeout=300s >/dev/null \
    || { bad "the realm import did not finish"; exit 1; }
  ok "Keycloak ready at https://keycloak.apps-crc.testing, realm tutorial imported"
  gateway_trust
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
  local btp=0
  has_btp || btp=$?
  [ $btp -ne 2 ] || assert "for Gateways: the API server says whether it serves BackendTLSPolicies" "answered" "no answer"
  if [ $btp -eq 0 ]; then
    assert "for Gateways: BackendTLSPolicy keycloak-service expects the Service's name" "keycloak-service.keycloak.svc" \
      "$($KUBE get backendtlspolicy keycloak-service -n "$NS" -o jsonpath='{.spec.validation.hostname}' 2>/dev/null)"
    assert "...and trusts Keycloak's CA (ConfigMap keycloak-ca = Secret keycloak-tls's ca.crt)" "same" \
      "$([ -n "$($KUBE get configmap keycloak-ca -n "$NS" -o jsonpath='{.data.ca\.crt}' 2>/dev/null)" ] \
         && [ "$($KUBE get configmap keycloak-ca -n "$NS" -o jsonpath='{.data.ca\.crt}')" = "$($KUBE get secret keycloak-tls -n "$NS" -o jsonpath='{.data.ca\.crt}' | base64 -d)" ] \
         && echo same || echo differ)"
  fi

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
  local wipe='' pv CSV btp=0
  case "${1:-}" in
    "") ;;
    --delete-data) wipe=yes ;;
    *) echo "usage: ./run.sh clean [--delete-data]"; exit 2 ;;
  esac
  # Argo CD would put everything back as it is deleted. Modules 17, 18 and 19
  # keep objects in this namespace too, so their Applications pause with it.
  app_pause 16-keycloak 17-keycloak-jwt 18-keycloak-ldap 19-shop-gateway
  warn=$($KUBE get securitypolicy -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null)
  [ -n "$warn" ] && echo "  note: SecurityPolicies that may use this Keycloak: $warn"
  if ! pv=$($KUBE get pvc data-postgres-0 -n "$NS" -o jsonpath='{.spec.volumeName}' 2>&1); then
    case "$pv" in
      (*NotFound*) pv='' ;;
      (*) bad "cannot read claim data-postgres-0 - nothing deleted: $pv"; return 1 ;;
    esac
  fi
  # Read before the Subscription goes: afterwards nothing names the operator's CSV.
  if ! CSV=$($KUBE get subscription rhbk-operator -n "$NS" -o jsonpath='{.status.installedCSV}' 2>&1); then
    case "$CSV" in
      (*NotFound*) CSV='' ;;
      (*) bad "cannot read Subscription rhbk-operator's CSV - nothing deleted: $CSV"; return 1 ;;
    esac
  fi
  has_btp || btp=$?
  [ $btp -ne 2 ] || { bad "cannot tell whether a BackendTLSPolicy is to be deleted - nothing deleted"; return 1; }
  if [ -n "$wipe" ]; then
    echo "  --delete-data: deleting namespace $NS - the database (realms tutorial and corp, their users and"
    echo "  sessions), claim data-postgres-0${pv:+ and volume $pv}, and what modules 17, 18 and 19 keep in $NS"
    # The volume outlives its claim here: CRC's StorageClass has reclaimPolicy
    # Retain, and an earlier clean left a Released PV - and the data on the
    # node's disk - behind (measured). Mark it Delete while the claim exists.
    if [ -n "$pv" ] && ! $KUBE patch pv "$pv" --type=merge \
         -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' >/dev/null; then
      bad "cannot mark volume $pv for deletion - nothing deleted"
      return 1
    fi
  fi
  checked "delete realm import tutorial" "$KUBE" delete keycloakrealmimport tutorial -n "$NS" --ignore-not-found
  checked "delete Keycloak keycloak" "$KUBE" delete keycloak keycloak -n "$NS" --ignore-not-found --wait=true
  checked "delete Subscription rhbk-operator" "$KUBE" delete subscription rhbk-operator -n "$NS" --ignore-not-found
  if [ -n "$CSV" ]; then
    checked "delete the operator's CSV $CSV" "$KUBE" delete csv "$CSV" -n "$NS" --ignore-not-found
  fi
  if [ -n "$wipe" ]; then
    checked "delete namespace $NS (the full wipe did not complete)" "$KUBE" delete ns "$NS" --wait=false
    ok "namespace $NS deletion requested; it removes the database and claim data-postgres-0${pv:+, and volume $pv}"
  else
    # Everything else this module applied, but not the Namespace (10-operator.yaml
    # holds it). Deleting the StatefulSet leaves its claim: a StatefulSet's claims
    # are kept unless persistentVolumeClaimRetentionPolicy says otherwise, and
    # 20-postgres.yaml sets none.
    checked "delete OperatorGroup keycloak" "$KUBE" delete operatorgroup keycloak -n "$NS" --ignore-not-found
    if [ $btp -eq 0 ]; then
      checked "delete BackendTLSPolicy keycloak-service" "$KUBE" delete -f manifests/70-backend-tls-policy.yaml --ignore-not-found
    fi
    checked "delete ConfigMap keycloak-ca" "$KUBE" delete configmap keycloak-ca -n "$NS" --ignore-not-found
    checked "delete the Route, the Keycloak resource, the certificate and PostgreSQL" \
      "$KUBE" delete -f manifests/50-route.yaml -f manifests/40-keycloak.yaml -f manifests/30-certificate.yaml \
      -f manifests/20-postgres.yaml --ignore-not-found --wait=true
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
    || echo "  note: to bring the lab back: ./run.sh deploy, then ../18-keycloak-ldap/run.sh deploy, ../17-keycloak-jwt/run.sh deploy and ../19-shop-gateway/run.sh deploy - each resumes its Argo CD Application"
}

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean "${2:-}" ;;
  pause) app_pause 16-keycloak ;; resume) app_resume 16-keycloak ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
