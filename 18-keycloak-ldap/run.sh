#!/usr/bin/env bash
# Module 18 — a realm federated from the cluster's LDAP.  ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=keycloak
. ../_shared/lib.sh

LDAP_HOST=ldaps-ldap-testing.apps-crc.testing
REALM=https://keycloak.apps-crc.testing/realms/corp
# The login gate, as 20-realm.yaml's customUserSearchFilter states it.
GATE='(memberOf=cn=app-ssb-autobahnusers,ou=Groups,dc=ephico2real,dc=com)'
BIND_DN=cn=keycloak-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com
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
  if [ -z "$wire" ] || [ -z "$owner" ] || [ "$wire" != "$owner" ]; then
    bad "the root from the wire is not the PKI owner's - nothing trusted"
    echo "      wire:  ${wire:-<unreadable>}"
    echo "      owner: ${owner:-<openshift-config/ca-config-map unreadable>}"
    exit 1
  fi
  ok "the root from the wire matches openshift-config/ca-config-map: $wire"
}

# secret_data_changed - when Secret ldap-root-ca's data was last written: the newest
# managedFields entry that owns f:data. An entry for metadata alone (the annotation
# `oc apply` adds to a Secret made by `oc create`) is not a change of the root, and
# measured, it does not restart Keycloak. Empty when the Secret cannot be read.
secret_data_changed() {
  $KUBE get secret ldap-root-ca -n "$NS" --show-managed-fields -o json 2>/dev/null | python3 -c '
import json, sys
m = json.load(sys.stdin)["metadata"].get("managedFields", [])
print(max((f["time"] for f in m if "f:data" in f.get("fieldsV1", {})), default=""))' 2>/dev/null
}
# truststore_loaded - "yes" only when the running Keycloak container started AFTER
# the Secret's data last changed AND its start-up log names the file. A log line
# alone proves nothing: a pod started before a change names the same file, holding
# the old root. Unreadable times count as "no".
truststore_loaded() {
  local changed started
  changed=$(secret_data_changed)
  started=$($KUBE get pod keycloak-0 -n "$NS" -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null)
  if [ -n "$changed" ] && [ -n "$started" ] && [[ "$started" > "$changed" ]] \
     && $KUBE logs keycloak-0 -n "$NS" 2>/dev/null | grep "TruststoreBuilder.*$TRUSTED" >/dev/null; then
    echo yes
  else
    echo no
  fi
}
# realm_state - "present" or "absent" for realm corp, from the admin API; anything
# but a 200 or a 404 is "unknown: <status>", never taken for either.
realm_state() {
  local out
  if out=$(./admin.sh GET /admin/realms/corp 2>&1); then echo present; return; fi
  case "$(tail -n 1 <<<"$out")" in
    ("HTTP 404") echo absent ;;
    (*) echo "unknown: $(tail -n 1 <<<"$out")" ;;
  esac
}

deploy() {
  need_keycloak
  say "deploying realm corp into $NS"
  [ "$($KUBE get keycloak keycloak -n "$NS" -o jsonpath='{.spec.truststores.ldap-root-ca.secret.name}')" = ldap-root-ca ] \
    || { bad "Keycloak has no truststore ldap-root-ca - re-apply ../16-keycloak/manifests/40-keycloak.yaml, which declares it"; exit 1; }
  local dir loaded=no state
  dir=$(mktemp -d) || { bad "could not make a temporary directory"; exit 1; }
  # fetch_root exits on a mismatch; the trap removes the fetched chain either way.
  trap 'rm -rf -- "$dir"' EXIT
  fetch_root "$dir"
  # Write the Secret only when it does not already hold this root: a new or changed
  # Secret makes the operator restart Keycloak (it keeps a hash of the Secrets it
  # mounts) - measured 46 s after the change - and the new pod loads the root.
  if [ "$($KUBE get secret ldap-root-ca -n "$NS" -o jsonpath='{.data.ldap-root-ca\.pem}' 2>/dev/null | base64 -d | fingerprint 2>/dev/null)" \
       != "$(fingerprint < "$dir/ldap-root-ca.pem")" ]; then
    $KUBE create secret generic ldap-root-ca -n "$NS" --from-file=ldap-root-ca.pem="$dir/ldap-root-ca.pem" \
      --dry-run=client -o yaml | $KUBE apply -f - >/dev/null \
      || { bad "Secret ldap-root-ca could not be written"; exit 1; }
    ok "Secret ldap-root-ca written; waiting for the operator to restart Keycloak"
  fi
  rm -rf -- "$dir"; trap - EXIT
  # Trusted only when a Keycloak that started after the root last changed has
  # loaded it. Five minutes without that is a failure, never "trusted".
  for _ in $(seq 1 60); do
    [ "$(truststore_loaded)" = yes ] && { loaded=yes; break; }
    sleep 5
  done
  [ "$loaded" = yes ] \
    || { bad "no Keycloak started after Secret ldap-root-ca last changed ($(secret_data_changed)) has loaded it - oc get pod keycloak-0 -n $NS"; exit 1; }
  $KUBE wait pod/keycloak-0 -n "$NS" --for=condition=Ready --timeout=600s >/dev/null \
    || { bad "keycloak-0 never Ready after the truststore change - oc describe pod keycloak-0 -n $NS"; exit 1; }
  ok "Keycloak trusts the directory's root"

  $KUBE apply -f manifests/10-bind-secret.yaml >/dev/null \
    || { bad "Secret keycloak-ldap-bind could not be applied"; exit 1; }
  # An import only creates. With the realm gone but its import still Done, applying
  # the import again does nothing (README step 13, measured): delete the import, so
  # the apply below creates it anew and its Job runs.
  state=$(realm_state)
  case "$state" in
    present) ;;
    absent)
      if $KUBE get keycloakrealmimport corp -n "$NS" >/dev/null 2>&1; then
        $KUBE delete keycloakrealmimport corp -n "$NS" >/dev/null \
          || { bad "the old import of the missing realm corp could not be deleted"; exit 1; }
        ok "realm corp is missing, its import was not: import deleted, to run again"
      fi ;;
    *) bad "cannot tell whether realm corp exists ($state) - nothing changed"; exit 1 ;;
  esac
  $KUBE apply -f manifests/20-realm.yaml >/dev/null \
    || { bad "the realm import could not be applied"; exit 1; }
  $KUBE wait keycloakrealmimport/corp -n "$NS" --for=condition=Done --timeout=300s >/dev/null \
    || { bad "the realm import did not finish - oc get keycloakrealmimport corp -n $NS -o yaml"; exit 1; }
  [ "$(realm_state)" = present ] \
    || { bad "the import says Done, but realm corp does not exist - README step 13"; exit 1; }
  ok "realm corp exists, federated from ldaps://$LDAP_HOST:443"
}

# claims - the claims of the access token on stdin (or a token.sh "no token: ..."
# error), one "name value" per line. The token goes to Python on stdin, never in
# its argv, where any process on the machine could read it.
claims() {
  python3 -c '
import base64, json, sys
t = sys.stdin.read().strip()
if t.count(".") != 2:
    print("error", t); sys.exit()
p = t.split(".")[1]
c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
for k in ("iss", "azp", "preferred_username"):
    print(k, c.get(k))
aud = c.get("aud"); print("aud", " ".join(sorted(aud if isinstance(aud, list) else [aud])))
print("roles", " ".join(sorted(c.get("realm_access", {}).get("roles", []))))'
}
claim() { sed -n "s/^$1 //p" <<<"$2"; }
# has <word> <words> - "yes" when <word> is one of the space-separated <words>, exactly.
has() { case " $2 " in (*" $1 "*) echo yes ;; (*) echo no ;; esac; }
# gate_members - the people the directory itself lists behind the gate, as
# Keycloak's bind account sees them: read-only, the password on stdin.
gate_members() {
  $KUBE get secret keycloak-ldap-bind -n "$NS" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d \
    | $KUBE exec -i -n ldap-testing deploy/openldap-server -c openldap -- \
        ldapsearch -x -LLL -o ldif-wrap=no -H ldap://localhost:389 -D "$BIND_DN" -y /dev/stdin \
        -b ou=People,dc=ephico2real,dc=com "$GATE" uid 2>/dev/null \
    | sed -n 's/^uid: //p' | sort | paste -sd' ' -
}
# corp_users - the user names realm corp lists (the same listing imports them).
corp_users() {
  ./admin.sh GET '/admin/realms/corp/users?briefRepresentation=true&max=100' 2>/dev/null \
    | python3 -c 'import json, sys; print(" ".join(sorted(u["username"] for u in json.load(sys.stdin))))' 2>/dev/null
}

verify() {
  need_keycloak
  client_ready

  say "1. the directory's root, checked and trusted"
  local owner root_fp
  owner=$(owner_fingerprint 2>/dev/null)
  root_fp=$($KUBE get secret ldap-root-ca -n "$NS" -o jsonpath='{.data.ldap-root-ca\.pem}' 2>/dev/null | base64 -d | fingerprint 2>/dev/null)
  # Two unreadable fingerprints are equal strings; neither may be empty.
  assert "Secret ldap-root-ca holds the PKI owner's root" "yes" \
    "$([ -n "$owner" ] && [ -n "$root_fp" ] && [ "$owner" = "$root_fp" ] && echo yes || echo "no (owner [$owner], Secret [$root_fp])")"
  assert "Keycloak declares the truststore (module 16's resource)" "ldap-root-ca" \
    "$($KUBE get keycloak keycloak -n "$NS" -o jsonpath='{.spec.truststores.ldap-root-ca.secret.name}')"
  assert "...the operator mounts it into keycloak-0" "/opt/keycloak/conf/truststores/secret-ldap-root-ca" \
    "$($KUBE get pod keycloak-0 -n "$NS" -o jsonpath='{.spec.containers[0].volumeMounts[?(@.name=="truststore-secret-ldap-root-ca")].mountPath}')"
  assert "...and a Keycloak started after its last change loaded it" "yes" "$(truststore_loaded)"

  say "2. realm corp and its LDAP provider"
  assert "realm import Done" "True" \
    "$($KUBE get keycloakrealmimport corp -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}')"
  assert "realm corp exists" "present" "$(realm_state)"
  assert "provider: test connection" "HTTP 204" "$(./admin.sh test-ldap connection | tail -n 1)"
  assert "provider: test authentication (the bind account)" "HTTP 204" "$(./admin.sh test-ldap authentication | tail -n 1)"

  say "3. who gets a corp token"
  local S L B C gate
  S=$(./token.sh sarah.jones 2>&1 | claims)
  assert_contains "sarah.jones (gate member): issued by corp" "iss $REALM" "$S"
  assert "sarah.jones: for shop-api (aud)"                    "yes" "$(has shop-api "$(claim aud "$S")")"
  assert "sarah.jones: role admin, from her LDAP group"       "yes" "$(has admin "$(claim roles "$S")")"
  L=$(./token.sh lateef.o 2>&1 | claims)
  assert "lateef.o (gate member): a token"                    "lateef.o" "$(claim preferred_username "$L")"
  assert "lateef.o: no admin (not in keycloak-admin)"         "no" "$(has admin "$(claim roles "$L")")"
  B=$(./token.sh bob.wilson 2>&1 | claims)
  assert_contains "bob.wilson (outside the gate): no token"   "error no token: {'error': 'invalid_grant'" "$B"
  assert "...because Keycloak does not find him"              "[]" \
    "$(./admin.sh GET '/admin/realms/corp/users?username=bob.wilson&exact=true')"
  C=$(./token.sh charlie.brown 2>&1 | claims)
  assert_contains "charlie.brown (outside the gate): no token" "error no token: {'error': 'invalid_grant'" "$C"
  assert "...because Keycloak does not find him"              "[]" \
    "$(./admin.sh GET '/admin/realms/corp/users?username=charlie.brown&exact=true')"
  # The same people, not just as many: corp's users against the directory's own
  # answer to the gate. An empty answer from the directory proves nothing.
  gate=$(gate_members)
  assert "corp's users are exactly the gate's members in the directory" "${gate:-<directory unreadable>}" "$(corp_users)"

  say "4. the name and the CA must both match"
  assert_contains "the in-cluster Service name: its certificate names it too" "HTTP 204" \
    "$(./admin.sh test-ldap connection ldaps://openldap-service.ldap-testing.svc.cluster.local:636)"
  assert_contains "a name the certificate lacks -> refused" '"errorMessage":"SSLHandshakeFailed"' \
    "$(./admin.sh test-ldap connection ldaps://openldap-service.ldap-testing:636)"
  assert_contains "a certificate from another CA -> refused" '"errorMessage":"SSLHandshakeFailed"' \
    "$(./admin.sh test-ldap connection ldaps://keycloak.apps-crc.testing:443)"
  summary
}

# remove <kind> <name> - delete one of this module's objects and say what really
# happened: deleted, already absent, or the error (a failure).
remove() {
  local out
  out=$($KUBE delete "$1" "$2" -n "$NS" --ignore-not-found 2>&1) \
    || { bad "$1/$2 not deleted: $out"; return 1; }
  if [ -n "$out" ]; then ok "$out"; else ok "$1/$2 already absent"; fi
}

clean() {
  local out failed=0
  # The realm first: deleting the KeycloakRealmImport leaves the realm it made. If
  # the realm cannot be removed, stop - its import and Secrets stay, for a retry.
  out=$(./admin.sh DELETE /admin/realms/corp 2>&1) \
    || { bad "realm corp not deleted: $(tail -n 1 <<<"$out") - nothing else removed"; return 1; }
  ok "realm corp: $out"
  remove keycloakrealmimport corp || failed=1
  remove secret keycloak-ldap-bind || failed=1
  # Module 16's truststore stays declared (optional: true); without the Secret the
  # operator restarts Keycloak once more, trusting the directory no longer.
  remove secret ldap-root-ca || failed=1
  [ "$failed" -eq 0 ] || return 1
  ok "module 16's Keycloak and realm tutorial are left as they were"
}

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
