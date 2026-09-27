#!/usr/bin/env bash
# Module 18 — a realm federated from the cluster's LDAP.  ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=keycloak
. ../_shared/lib.sh

LDAP_HOST=ldaps-ldap-testing.apps-crc.testing
REALM=https://keycloak.apps-crc.testing/realms/corp
# The file Keycloak reads the root from, once the operator mounts Secret ldap-root-ca
# (module 16's Keycloak resource, spec.truststores.ldap-root-ca), as Keycloak's
# TruststoreBuilder names it at start-up: /opt/keycloak/bin/../conf/truststores/...
# The checks below grep for it without -q: grep -q stops reading at the first
# match, oc logs then dies of SIGPIPE, and pipefail (lib.sh) fails the pipeline.
TRUSTED=conf/truststores/secret-ldap-root-ca/ldap-root-ca.pem

# Module 16's lab must be up: this module adds a realm to that Keycloak.
need_keycloak() {
  [ "$($KUBE get keycloak keycloak -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] \
    || { bad "module 16's Keycloak is not running - ../16-keycloak/run.sh deploy"; exit 1; }
}
# fingerprint - the SHA-256 fingerprint of the one certificate on stdin.
fingerprint() { openssl x509 -noout -fingerprint -sha256 | sed 's/^.*=//'; }
# The PKI owner's copy of the directory's root: the cluster already trusts it for
# OpenShift's own LDAP login (ldap-local), so it is a source trusted out of band.
owner_fingerprint() {
  $KUBE extract configmap/ca-config-map -n openshift-config --keys=ca.crt --to=- 2>/dev/null | fingerprint
}

# fetch_root <dir> - the self-signed certificate in the chain the directory sends
# on its public name, written to <dir>/ldap-root-ca.pem. Fatal when the chain has
# none, or when it is not the root the PKI owner published: nothing is trusted
# on the strength of the handshake alone.
fetch_root() {
  local dir=$1 f s i
  openssl s_client -showcerts -servername "$LDAP_HOST" -connect "$LDAP_HOST:443" </dev/null 2>/dev/null \
    | awk -v d="$dir" '/-----BEGIN CERTIFICATE-----/{n++; f=1} f{print > (d "/chain-" n ".pem")} /-----END CERTIFICATE-----/{f=0}'
  for f in "$dir"/chain-*.pem; do
    [ -s "$f" ] || continue
    s=$(openssl x509 -in "$f" -noout -subject | sed 's/^subject=//')
    i=$(openssl x509 -in "$f" -noout -issuer | sed 's/^issuer=//')
    [ "$s" = "$i" ] && cp "$f" "$dir/ldap-root-ca.pem"
  done
  [ -s "$dir/ldap-root-ca.pem" ] || { bad "no self-signed root in the chain $LDAP_HOST:443 sent - nothing trusted"; exit 1; }
  local wire owner
  wire=$(fingerprint < "$dir/ldap-root-ca.pem")
  owner=$(owner_fingerprint)
  if [ -z "$owner" ] || [ "$wire" != "$owner" ]; then
    bad "the root from the wire is not the PKI owner's - nothing trusted"
    echo "      wire:  $wire"
    echo "      owner: ${owner:-<openshift-config/ca-config-map unreadable>}"
    exit 1
  fi
  ok "the root from the wire matches openshift-config/ca-config-map: $wire"
}

deploy() {
  need_keycloak
  say "deploying realm corp into $NS"
  [ "$($KUBE get keycloak keycloak -n "$NS" -o jsonpath='{.spec.truststores.ldap-root-ca.secret.name}')" = ldap-root-ca ] \
    || { bad "Keycloak has no truststore ldap-root-ca - re-apply ../16-keycloak/manifests/40-keycloak.yaml, which declares it"; exit 1; }
  local dir pod; dir=$(mktemp -d)
  fetch_root "$dir"
  # Write the Secret only when it does not already hold this root: a new or changed
  # Secret makes the operator restart Keycloak (it keeps a hash of the Secrets it
  # mounts) - measured 46 s after the change - and the new pod loads the root.
  if [ "$($KUBE get secret ldap-root-ca -n "$NS" -o jsonpath='{.data.ldap-root-ca\.pem}' 2>/dev/null | base64 -d | fingerprint 2>/dev/null)" \
       != "$(fingerprint < "$dir/ldap-root-ca.pem")" ]; then
    pod=$($KUBE get pod keycloak-0 -n "$NS" -o jsonpath='{.metadata.uid}')
    $KUBE create secret generic ldap-root-ca -n "$NS" --from-file=ldap-root-ca.pem="$dir/ldap-root-ca.pem" \
      --dry-run=client -o yaml | $KUBE apply -f - >/dev/null
    ok "Secret ldap-root-ca written; waiting for the operator to restart Keycloak"
    # The old pod's log names the same file, so wait for a new pod, not for the line.
    for _ in $(seq 1 60); do
      [ "$($KUBE get pod keycloak-0 -n "$NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)" != "$pod" ] && break
      sleep 5
    done
    # The pod's own readiness: the Keycloak resource's Ready may still be the old pod's.
    $KUBE wait pod/keycloak-0 -n "$NS" --for=condition=Ready --timeout=600s >/dev/null
  fi
  rm -rf "$dir"
  $KUBE wait keycloak/keycloak -n "$NS" --for=condition=Ready --timeout=600s >/dev/null \
    || { bad "Keycloak never Ready after the truststore change - oc get keycloak keycloak -n $NS -o yaml"; exit 1; }
  $KUBE logs keycloak-0 -n "$NS" 2>/dev/null | grep "TruststoreBuilder.*$TRUSTED" >/dev/null \
    || { bad "Keycloak did not load $TRUSTED - oc logs keycloak-0 -n $NS | grep TruststoreBuilder"; exit 1; }
  ok "Keycloak trusts the directory's root"
  $KUBE apply -f manifests/10-bind-secret.yaml -f manifests/20-realm.yaml >/dev/null
  $KUBE wait keycloakrealmimport/corp -n "$NS" --for=condition=Done --timeout=300s >/dev/null \
    || { bad "the realm import did not finish - oc get keycloakrealmimport corp -n $NS -o yaml"; exit 1; }
  ok "realm corp imported, federated from ldaps://$LDAP_HOST:443"
}

# claims <token or "no token: ..."> - the access token's claims, one "name value" per line.
claims() {
  python3 -c '
import base64, json, sys
t = sys.argv[1]
if t.count(".") != 2:
    print("error", t); sys.exit()
p = t.split(".")[1]
c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
for k in ("iss", "azp", "preferred_username"):
    print(k, c.get(k))
aud = c.get("aud"); print("aud", " ".join(sorted(aud if isinstance(aud, list) else [aud])))
print("roles", " ".join(sorted(c.get("realm_access", {}).get("roles", []))))' "$1"
}
claim() { sed -n "s/^$1 //p" <<<"$2"; }
# has <word> <words> - "yes" when <word> is one of the space-separated <words>, exactly.
has() { case " $2 " in (*" $1 "*) echo yes ;; (*) echo no ;; esac; }

verify() {
  need_keycloak
  client_ready

  say "1. the directory's root, checked and trusted"
  local root
  root=$($KUBE get secret ldap-root-ca -n "$NS" -o jsonpath='{.data.ldap-root-ca\.pem}' 2>/dev/null | base64 -d)
  assert "Secret ldap-root-ca holds the PKI owner's root" "$(owner_fingerprint)" \
    "$(printf '%s\n' "$root" | fingerprint 2>/dev/null)"
  assert "Keycloak declares the truststore (module 16's resource)" "ldap-root-ca" \
    "$($KUBE get keycloak keycloak -n "$NS" -o jsonpath='{.spec.truststores.ldap-root-ca.secret.name}')"
  assert "...the operator mounts it into keycloak-0" "/opt/keycloak/conf/truststores/secret-ldap-root-ca" \
    "$($KUBE get pod keycloak-0 -n "$NS" -o jsonpath='{.spec.containers[0].volumeMounts[?(@.name=="truststore-secret-ldap-root-ca")].mountPath}')"
  assert "...and Keycloak loaded it when it started" "yes" \
    "$($KUBE logs keycloak-0 -n "$NS" 2>/dev/null | grep "TruststoreBuilder.*$TRUSTED" >/dev/null && echo yes || echo no)"

  say "2. realm corp and its LDAP provider"
  assert "realm import Done" "True" \
    "$($KUBE get keycloakrealmimport corp -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}')"
  assert "provider: test connection" "HTTP 204" "$(./admin.sh test-ldap connection | tail -n 1)"
  assert "provider: test authentication (the bind account)" "HTTP 204" "$(./admin.sh test-ldap authentication | tail -n 1)"

  say "3. who gets a corp token"
  local S L B
  S=$(claims "$(./token.sh sarah.jones 2>&1)")
  assert_contains "sarah.jones (gate member): issued by corp" "iss $REALM" "$S"
  assert "sarah.jones: for shop-api (aud)"                    "yes" "$(has shop-api "$(claim aud "$S")")"
  assert "sarah.jones: role admin, from her LDAP group"       "yes" "$(has admin "$(claim roles "$S")")"
  L=$(claims "$(./token.sh lateef.o 2>&1)")
  assert "lateef.o (gate member): a token"                    "lateef.o" "$(claim preferred_username "$L")"
  assert "lateef.o: no admin (not in keycloak-admin)"         "no" "$(has admin "$(claim roles "$L")")"
  B=$(claims "$(./token.sh bob.wilson 2>&1)")
  assert_contains "bob.wilson (outside the gate): no token"   "error no token: {'error': 'invalid_grant'" "$B"
  assert "...because Keycloak does not find him"              "[]" \
    "$(./admin.sh GET '/admin/realms/corp/users?username=bob.wilson&exact=true')"
  assert "only gate members are in corp (7 of the directory's 9)" "7" \
    "$(./admin.sh GET '/admin/realms/corp/users?briefRepresentation=true&max=100' | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))')"

  say "4. the name and the CA must both match"
  assert_contains "the in-cluster Service name: its certificate names it too" "HTTP 204" \
    "$(./admin.sh test-ldap connection ldaps://openldap-service.ldap-testing.svc.cluster.local:636)"
  assert_contains "a name the certificate lacks -> refused" '"errorMessage":"SSLHandshakeFailed"' \
    "$(./admin.sh test-ldap connection ldaps://openldap-service.ldap-testing:636)"
  assert_contains "a certificate from another CA -> refused" '"errorMessage":"SSLHandshakeFailed"' \
    "$(./admin.sh test-ldap connection ldaps://keycloak.apps-crc.testing:443)"
  summary
}

clean() {
  # The realm first: deleting the KeycloakRealmImport leaves the realm it made.
  if ./admin.sh GET /admin/realms/corp >/dev/null 2>&1; then
    ./admin.sh DELETE /admin/realms/corp >/dev/null && ok "realm corp deleted"
  fi
  $KUBE delete keycloakrealmimport corp -n "$NS" --ignore-not-found >/dev/null 2>&1
  $KUBE delete -f manifests/10-bind-secret.yaml --ignore-not-found >/dev/null 2>&1
  # Module 16's truststore stays declared (optional: true); without the Secret the
  # operator restarts Keycloak once more, trusting the directory no longer.
  $KUBE delete secret ldap-root-ca -n "$NS" --ignore-not-found >/dev/null 2>&1
  ok "the import, the bind Secret and ldap-root-ca removed; module 16's Keycloak and realm tutorial are left as they were"
}

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
