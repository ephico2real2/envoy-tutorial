#!/usr/bin/env bash
# Module 18 — a realm federated from the cluster's LDAP.  ./run.sh deploy | verify | clean | pause | resume
cd "$(dirname "$0")"
NS=keycloak
. ../_shared/lib.sh
. ../_shared/argocd.sh

LDAP_HOST=ldaps-ldap-testing.apps-crc.testing
REALM=https://keycloak.apps-crc.testing/realms/corp
# The login gate, as 20-realm.yaml's customUserSearchFilter states it.
GATE='(memberOf=cn=app-ssb-autobahnusers,ou=Groups,dc=ephico2real,dc=com)'
BIND_DN=cn=keycloak-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com
# The file Keycloak reads the root from, once the operator mounts Secret ldap-root-ca
# (module 16's Keycloak resource, spec.truststores.ldap-root-ca). The kubelet
# projects a Secret as a versioned directory, ..<timestamp>.<n>, which ..data and
# this file link to; a change of the Secret's DATA makes a new one, a change of its
# metadata does not (measured: an annotation write left the directory as it was).
TRUSTED=/opt/keycloak/conf/truststores/secret-ldap-root-ca/ldap-root-ca.pem
# generation - the versioned part of the path on stdin, as
# secret-ldap-root-ca/..20<...>/ldap-root-ca.pem; the last one when there are several.
generation() { grep -o 'secret-ldap-root-ca/\.\.20[^/]*/ldap-root-ca\.pem' | tail -n 1; }

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

# truststore_loaded - "yes" only when Keycloak loaded the root the Secret holds now:
#   - the Secret's certificate and the file mounted in keycloak-0 have the same
#     fingerprint (the kubelet has projected the current data), and
#   - the generation Keycloak's start-up log names (TruststoreBuilder lists the
#     plain, ..data and ..20<...> paths) is the one the file links to now.
# A Keycloak started before a data change logged an older generation; nothing here
# compares clocks. Any unreadable value is "no". Certificates only - no credential.
truststore_loaded() {
  local secret_fp mounted_fp loaded current
  secret_fp=$($KUBE get secret ldap-root-ca -n "$NS" -o jsonpath='{.data.ldap-root-ca\.pem}' 2>/dev/null | base64 -d | fingerprint 2>/dev/null)
  mounted_fp=$($KUBE exec -n "$NS" keycloak-0 -- cat "$TRUSTED" 2>/dev/null | fingerprint 2>/dev/null)
  loaded=$($KUBE logs keycloak-0 -n "$NS" 2>/dev/null | grep TruststoreBuilder | generation)
  current=$($KUBE exec -n "$NS" keycloak-0 -- readlink -f "$TRUSTED" 2>/dev/null | generation)
  if [ -n "$secret_fp" ] && [ "$secret_fp" = "$mounted_fp" ] && [ -n "$loaded" ] && [ "$loaded" = "$current" ]; then
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

# client_secret <Secret> - the Secret a confidential client of realm corp gets from the
# import's placeholder: shop-kiosk-client for shop-kiosk (module 19), shop-envoy-client
# for shop-envoy (module 20). Generated once, a random value from python's secrets
# module, straight into the Secret on stdin; an existing one is kept, never replaced -
# the realm keeps the value it was imported with.
client_secret() {
  if $KUBE get secret "$1" -n "$NS" >/dev/null 2>&1; then
    ok "Secret $1 kept"
    return 0
  fi
  python3 -c 'import secrets; print(secrets.token_urlsafe(32), end="")' \
    | $KUBE create secret generic "$1" -n "$NS" --from-file=client-secret=/dev/stdin >/dev/null \
    || { bad "Secret $1 could not be created"; exit 1; }
  ok "Secret $1 generated"
}
# client_secret_state <client> <Secret> - "same" when realm corp's client <client> has
# the value Secret <Secret> holds, "differ" when not, "unknown: ..." when either cannot
# be read. Both values reach python on stdin and fd 3, and are never printed.
client_secret_state() {
  local id
  id=$(./admin.sh GET "/admin/realms/corp/clients?clientId=$1" 2>/dev/null \
    | python3 -c 'import json, sys; c = json.load(sys.stdin); print(c[0]["id"] if c else "")' 2>/dev/null)
  [ -n "$id" ] || { echo "unknown: realm corp has no client $1"; return; }
  ./admin.sh GET "/admin/realms/corp/clients/$id/client-secret" 2>/dev/null | python3 -c '
import base64, json, sys
realm = json.load(sys.stdin).get("value", "")
secret = base64.b64decode(open(3).read().strip() or "").decode()
print("unknown: an empty value" if not realm or not secret else "same" if realm == secret else "differ")' \
    3< <($KUBE get secret "$2" -n "$NS" -o jsonpath='{.data.client-secret}' 2>/dev/null) 2>/dev/null \
    || echo "unknown: unreadable"
}

# ldap_cache_policy - the live LDAP provider's cachePolicy in realm corp, or "unknown".
# An import only creates the realm: a realm imported before 20-realm.yaml said
# NO_CACHE keeps its old policy, and a directory change then waits for Keycloak's cache.
ldap_cache_policy() {
  ./admin.sh GET '/admin/realms/corp/components?type=org.keycloak.storage.UserStorageProvider&name=ldap' 2>/dev/null \
    | python3 -c 'import json, sys; c = json.load(sys.stdin); print(c[0]["config"].get("cachePolicy", ["DEFAULT (not set)"])[0] if len(c) == 1 else "unknown")' 2>/dev/null \
    || echo unknown
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
  # Trusted only when Keycloak's start-up log names the generation of the Secret's
  # current data. Five minutes without that is a failure, never "trusted".
  for _ in $(seq 1 60); do
    [ "$(truststore_loaded)" = yes ] && { loaded=yes; break; }
    sleep 5
  done
  [ "$loaded" = yes ] \
    || { bad "Keycloak has not loaded the current data of Secret ldap-root-ca - oc logs keycloak-0 -n $NS | grep TruststoreBuilder"; exit 1; }
  $KUBE wait pod/keycloak-0 -n "$NS" --for=condition=Ready --timeout=600s >/dev/null \
    || { bad "keycloak-0 never Ready after the truststore change - oc describe pod keycloak-0 -n $NS"; exit 1; }
  ok "Keycloak trusts the directory's root"

  $KUBE apply -f manifests/10-bind-secret.yaml >/dev/null \
    || { bad "Secret keycloak-ldap-bind could not be applied"; exit 1; }
  # Before the import: its Job reads these Secrets, and waits while one is missing.
  client_secret shop-kiosk-client
  client_secret shop-envoy-client
  # An import only creates. With the realm gone but its import still Done, applying
  # the import again does nothing (README step 13, measured): delete the import, so
  # the apply below creates it anew and its Job runs.
  state=$(realm_state)
  case "$state" in
    present) ;;
    absent)
      if $KUBE get keycloakrealmimport corp -n "$NS" >/dev/null 2>&1; then
        # Argo CD would create the deleted import again from git before the apply
        # below: this apply decides. The end of deploy resumes it.
        app_pause 18-keycloak-ldap
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
  # An import only creates: a realm imported before a client or its Secret existed (or
  # with an earlier value) keeps its own. Say so rather than report success.
  local client
  for client in shop-kiosk shop-envoy; do
    state=$(client_secret_state "$client" "$client-client")
    [ "$state" = same ] || { bad "client $client's secret in realm corp and Secret $client-client: $state - re-import corp (README step 13)"; exit 1; }
    ok "client $client's secret in realm corp is the one in Secret $client-client"
  done
  state=$(ldap_cache_policy)
  [ "$state" = NO_CACHE ] \
    || { bad "realm corp's LDAP provider has cachePolicy $state, not NO_CACHE - the realm predates it: re-import corp (README step 13)"; exit 1; }
  ok "the LDAP provider reads the directory at every login (cachePolicy NO_CACHE)"
  app_resume 18-keycloak-ldap
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
  assert "...and Keycloak loaded the Secret's current data at start-up" "yes" "$(truststore_loaded)"

  say "2. realm corp and its LDAP provider"
  assert "realm import Done" "True" \
    "$($KUBE get keycloakrealmimport corp -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}')"
  assert "realm corp exists" "present" "$(realm_state)"
  assert "provider: test connection" "HTTP 204" "$(./admin.sh test-ldap connection | tail -n 1)"
  assert "provider: test authentication (the bind account)" "HTTP 204" "$(./admin.sh test-ldap authentication | tail -n 1)"
  assert "provider: cachePolicy NO_CACHE - the directory is read at every login" "NO_CACHE" "$(ldap_cache_policy)"
  assert "client shop-kiosk (module 19): its secret is Secret shop-kiosk-client's" "same" "$(client_secret_state shop-kiosk shop-kiosk-client)"
  assert "client shop-envoy (module 20): its secret is Secret shop-envoy-client's" "same" "$(client_secret_state shop-envoy shop-envoy-client)"

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

# keycloak_restarted <uid of keycloak-0 before> - wait, at most five minutes each,
# for the operator to replace keycloak-0 and for the new Keycloak to be Ready.
# Removing a Secret that Keycloak mounts restarts it - measured: the pod was
# stopped 5 s after the delete. Until the old pod goes, the Keycloak resource can
# still say Ready, so wait for a new pod first. A timeout is a failure.
keycloak_restarted() {
  local now=
  for _ in $(seq 1 60); do
    now=$($KUBE get pod keycloak-0 -n "$NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)
    [ -n "$now" ] && [ "$now" != "$1" ] && break
    sleep 5
  done
  if [ -z "$now" ] || [ "$now" = "$1" ]; then
    bad "keycloak-0 was not replaced within 5 minutes of removing Secret ldap-root-ca - oc get pod keycloak-0 -n $NS"
    return 1
  fi
  if ! $KUBE wait pod/keycloak-0 -n "$NS" --for=condition=Ready --timeout=300s >/dev/null 2>&1 \
     || ! $KUBE wait keycloak/keycloak -n "$NS" --for=condition=Ready --timeout=300s >/dev/null 2>&1; then
    bad "the restarted Keycloak was not Ready within 5 minutes - oc get keycloak keycloak -n $NS -o yaml"
    return 1
  fi
  ok "Keycloak restarted and is Ready: the operator replaced keycloak-0 because its optional truststore Secret ldap-root-ca was removed"
}

clean() {
  local out failed=0 pod root
  # Argo CD would put the import and the bind Secret back as they are deleted. Modules
  # 19's and 20's shops sign in on this realm and copy Secrets shop-kiosk-client and
  # shop-envoy-client: their Applications pause too, so they do not keep re-applying a
  # shop that cannot sign in.
  app_pause 18-keycloak-ldap 19-shop-gateway 20-shop-envoy
  # The realm first: deleting the KeycloakRealmImport leaves the realm it made. If
  # the realm cannot be removed, stop - its import and Secrets stay, for a retry.
  out=$(./admin.sh DELETE /admin/realms/corp 2>&1) \
    || { bad "realm corp not deleted: $(tail -n 1 <<<"$out") - nothing else removed"; return 1; }
  ok "realm corp: $out"
  remove keycloakrealmimport corp || failed=1
  remove secret keycloak-ldap-bind || failed=1
  remove secret shop-kiosk-client || failed=1
  remove secret shop-envoy-client || failed=1
  # Module 16's truststore stays declared (optional: true). Removing the Secret it
  # names restarts Keycloak, so module 16's Keycloak is "as it was" only once the
  # restarted one is Ready - wait for it, unless the Secret was already gone.
  root=$($KUBE get secret ldap-root-ca -n "$NS" -o name 2>/dev/null)
  pod=$($KUBE get pod keycloak-0 -n "$NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)
  if remove secret ldap-root-ca; then
    [ -z "$root" ] || keycloak_restarted "$pod" || failed=1
  else
    failed=1
  fi
  [ "$failed" -eq 0 ] || return 1
  ok "module 16's Keycloak resource and realm tutorial are unchanged"
}

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  pause) app_pause 18-keycloak-ldap ;; resume) app_resume 18-keycloak-ldap ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
